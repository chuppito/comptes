import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:uuid/uuid.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:async'; // Obligatoire pour StreamSubscription
import 'package:app_links/app_links.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR', null);
  await Hive.initFlutter();
  await Hive.openBox("db");
  runApp(const App());
}

enum Frequence { ponctuel, jour, semaine, mois, trimestre, semestre, an }

class Operation {
  String id;
  String desc;
  double montant;
  bool depense;
  bool pointer;
  DateTime date;
  String banque;
  Frequence f;
  List<String> exclusions;

  Operation({
    required this.id,
    required this.desc,
    required this.montant,
    required this.depense,
    required this.date,
    required this.banque,
    this.pointer = false,
    this.f = Frequence.ponctuel,
    List<String>? exclusions,
  }) : exclusions = exclusions ?? [];

  Map toMap() => {
        "id": id,
        "d": desc,
        "m": montant,
        "dep": depense,
        "p": pointer,
        "dt": date.toIso8601String(),
        "b": banque,
        "f": f.index,
        "ex": exclusions
      };

  factory Operation.fromMap(Map m) => Operation(
        id: m["id"],
        desc: m["d"],
        montant: (m["m"]).toDouble(),
        depense: m["dep"],
        pointer: m["p"] ?? false,
        date: DateTime.parse(m["dt"]),
        banque: m["b"],
        f: Frequence.values[m["f"]],
        exclusions:
            m["ex"] != null ? List<String>.from(m["ex"]) : [],
      );

  bool occursOn(DateTime day) {
    if (exclusions
        .contains(DateFormat('yyyy-MM-dd').format(day))) {
      return false;
    }
    if (date.isAfter(day) && !isSameDay(date, day)) {
      return false;
    }
    switch (f) {
      case Frequence.ponctuel:
        return isSameDay(date, day);
      case Frequence.jour:
        return true;
      case Frequence.semaine:
        return date.weekday == day.weekday;
      case Frequence.mois:
        return date.day == day.day;
      case Frequence.trimestre:
        return date.day == day.day &&
            ((day.year - date.year) * 12 +
                        day.month -
                        date.month) %
                    3 ==
                0;
      case Frequence.semestre:
        return date.day == day.day &&
            ((day.year - date.year) * 12 +
                        day.month -
                        date.month) %
                    6 ==
                0;
      case Frequence.an:
        return date.day == day.day &&
            date.month == day.month;
    }
  }
}

/// ========= STORE OPTIMISÉ AVEC CACHE =========
class Store extends ChangeNotifier {
  static final I = Store._();
  Store._() {
    load();
  }

  final box = Hive.box("db");

  List<String> banques = [];
  String? active;
  List<Operation> ops = [];

  // Cache des soldes par banque
  final Map<String, Map<DateTime, double>>
      _cacheSoldesParBanque = {};

  Map<DateTime, double> _cacheForActive() {
    if (active == null) return {};
    return _cacheSoldesParBanque
        .putIfAbsent(active!, () => {});
  }

  void _clearCache() {
    _cacheSoldesParBanque.clear();
  }

  void load() {
    banques = (box.get("banques") ?? []).cast<String>();
    active = box.get("active");
    final raw = box.get("ops");
    if (raw != null) {
      ops = List.from(raw)
          .map((e) => Operation.fromMap(Map.from(e)))
          .toList();
    }
    _clearCache();
    notifyListeners();
  }

  void save() {
    box.put("banques", banques);
    box.put("active", active);
    box.put(
        "ops", ops.map((e) => e.toMap()).toList());
    _clearCache();
    notifyListeners();
  }

  double getSoldeAu(
      DateTime dateCible, bool seulementPointe) {
    if (active == null) return 0;

    final cache = _cacheForActive();

    DateTime cible = DateTime(dateCible.year,
        dateCible.month, dateCible.day);

    if (cache.containsKey(cible) && !seulementPointe) {
      return cache[cible]!;
    }

    DateTime base = DateTime(2023, 1, 1);

    double total;
    DateTime curseur;

    if (!seulementPointe && cache.isNotEmpty) {
      DateTime lastCachedDate =
          cache.keys.reduce((a, b) => a.isAfter(b) ? a : b);

      if (lastCachedDate.isAfter(cible)) {
        total = 0;
        curseur = base;
        cache.clear();
      } else {
        total = cache[lastCachedDate]!;
        curseur =
            lastCachedDate.add(const Duration(days: 1));
      }
    } else {
      total = 0;
      curseur = base;
      if (!seulementPointe) cache.clear();
    }

    while (curseur.isBefore(cible) ||
        isSameDay(curseur, cible)) {
      for (var o in ops.where(
          (x) => x.banque == active)) {
        if (o.occursOn(curseur)) {
          if (!seulementPointe || o.pointer) {
            total +=
                o.depense ? -o.montant : o.montant;
          }
        }
      }
      if (!seulementPointe) {
        cache[DateTime(curseur.year,
                curseur.month, curseur.day)] =
            total;
      }
      curseur =
          curseur.add(const Duration(days: 1));
    }

    return total;
  }
}
/// ============================================

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            primarySwatch: Colors.indigo,
            useMaterial3: false),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate
        ],
        supportedLocales: const [
          Locale('fr', 'FR')
        ],
        locale: const Locale('fr', 'FR'),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State createState() => _Home();
}

class _Home extends State<Home> {
  DateTime focus = DateTime.now();
  DateTime selected = DateTime.now();

  // --- LOGIQUE RÉCEPTION LIENS (MACRODROID) ---
  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  void _initDeepLinks() async {
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) => _handleDeepLink(uri));
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) _handleDeepLink(initialUri);
    } catch (e) {
      debugPrint("Erreur lien: $e");
    }
  }

  void _handleDeepLink(Uri uri) {
    if (uri.scheme == 'mesfinances' && uri.host == 'ajout') {
      final s = Store.I;
      
      // Extraction et distinction débit/crédit
      final String? debitStr = uri.queryParameters['montant']?.replaceAll(',', '.');
      final String? creditStr = uri.queryParameters['credit']?.replaceAll(',', '.');
      final bool isCredit = uri.queryParameters.containsKey('credit');
      final String? mStr = isCredit ? creditStr : debitStr;

      final m = double.tryParse(mStr ?? '0');
      final d = uri.queryParameters['desc'] ?? 'Achat Mobile';
      final b = uri.queryParameters['banque'];

      if (m != null && m > 0 && b != null && s.banques.contains(b)) {
        setState(() {
          s.ops.add(Operation(
            id: const Uuid().v4(),
            desc: d,
            montant: m,
            depense: isCredit ? false : true, 
            date: DateTime.now(),
            banque: b,
            f: Frequence.ponctuel,
            pointer: true,
          ));
          s.save();
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Ajouté : $d ($m €)"), 
              backgroundColor: isCredit ? Colors.blue : Colors.green,
            ),
          );
        }
      }
    }
  }
  // --- FIN LOGIQUE RÉCEPTION ---

  @override
  Widget build(context) {
    final s = Store.I;
    return AnimatedBuilder(
      animation: s,
      builder: (c, _) {
        final currentOps = s.ops
            .where((o) =>
                o.banque == s.active &&
                o.occursOn(selected))
            .toList();
        double soldeTotal =
            s.getSoldeAu(selected, false);
        double soldePointe =
            s.getSoldeAu(selected, true);
        return Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF1A237E),
            title: s.active == null
                ? const Text("Mes Comptes")
                : PopupMenuButton<String>(
                    onSelected: (v) {
                      setState(() {
                        s.active = v;
                        s.save();
                      });
                    },
                    itemBuilder: (ctx) => s.banques
                        .map((b) => PopupMenuItem(
                            value: b,
                            child: Text(b)))
                        .toList(),
                    child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(s.active!),
                          const Icon(Icons.arrow_drop_down)
                        ]),
                  ),
            actions: [
              // 1. Bouton AJOUTER (le nouveau)
              if (s.active != null)
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 28),
                  onPressed: () async {
                    final r = await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => Saisie(dateSelectionnee: selected)));
                    if (r != null) {
                      setState(() {
                        s.ops.add(r);
                        s.save();
                      });
                    }
                  },
                ),
              // 2. Bouton RECAPITULATIF
              if (s.active != null)
                IconButton(
                    icon: const Icon(Icons.bar_chart),
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const Recap()))),
              // 3. Bouton PARAMETRES
              IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const Parametres()))),
            ],
          ), // FIN DE L'APPBAR
          body: SafeArea(
            child: s.active == null
                ? Center(
                    child: ElevatedButton(
                        onPressed: _addBank,
                        child: const Text("Ajouter une banque")))
                : Column(children: [
                    TableCalendar(
                      locale: "fr_FR",
                      firstDay: DateTime.utc(2023),
                      lastDay: DateTime.utc(2035),
                      focusedDay: focus,
                      startingDayOfWeek:
                          StartingDayOfWeek
                              .monday,
                      rowHeight: 62,
                      selectedDayPredicate: (d) =>
                          isSameDay(d, selected),
                      onDaySelected: (d, f) =>
                          setState(() {
                        selected = d;
                        focus = f;
                      }),
                      headerStyle:
                          const HeaderStyle(
                              formatButtonVisible:
                                  false,
                              titleCentered: true),
                      calendarBuilders:
                          CalendarBuilders(
                        defaultBuilder:
                            (context, day,
                                focusedDay) {
                          return _buildDayCell(
                              day, s, false);
                        },
                        selectedBuilder:
                            (context, day,
                                focusedDay) {
                          return _buildDayCell(
                              day, s, true);
                        },
                        outsideBuilder: (context, day, focusedDay) {
                  return Opacity(
                    opacity: 0.5,
                    child: _buildDayCell(day, s, false),
                  );
                },
                markerBuilder: (context, day, events) {
                  return const SizedBox.shrink();
                },
              ),
            ),
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(
                              vertical: 10),
                      child: Column(children: [
                        Text(
                            "Solde au ${DateFormat('dd MMMM yyyy', 'fr_FR').format(selected)}",
                            style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 12)),
                        const SizedBox(height: 4),
                        Row(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .center,
                            children: [
                              Text(
                                  "${soldeTotal.toStringAsFixed(2)} €",
                                  style: TextStyle(
                                      fontSize: 22,
                                      fontWeight:
                                          FontWeight
                                              .bold,
                                      color: soldeTotal >=
                                              0
                                          ? Colors
                                              .green
                                          : Colors
                                              .red)),
                              const SizedBox(
                                  width: 8),
                              Text(
                                  "(✓ ${soldePointe.toStringAsFixed(2)} €)",
                                  style: const TextStyle(
                                      fontSize: 16,
                                      color: Colors
                                          .green,
                                      fontWeight:
                                          FontWeight
                                              .w500)),
                            ]),
                      ]),
                    ),
                    Expanded(
                        child: ListView.builder(
                            itemCount:
                                currentOps.length,
                            itemBuilder: (c, i) {
                              final o =
                                  currentOps[i];
                              return ListTile(
                                leading: Checkbox(
                                    value:
                                        o.pointer,
                                    activeColor:
                                        Colors
                                            .indigo,
                                    onChanged: (v) {
                                      setState(() {
                                        o.pointer =
                                            v!;
                                        Store.I
                                            .save();
                                      });
                                    }),
                                title: Text(o.desc,
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight
                                                .w500)),
                                subtitle: o.f ==
                                        Frequence
                                            .ponctuel
                                    ? null
                                    : Row(children: [
                                        const Icon(
                                            Icons
                                                .refresh,
                                            size: 12,
                                            color: Colors
                                                .grey),
                                        const SizedBox(
                                            width:
                                                4),
                                        Text(
                                            [
                                              "",
                                              "QUOTIDIEN",
                                              "HEBDO",
                                              "MENSUEL",
                                              "3 MOIS",
                                              "6 MOIS",
                                              "ANNUEL"
                                            ][o.f.index],
                                            style: const TextStyle(
                                                fontSize:
                                                    10,
                                                color: Colors
                                                    .grey))
                                      ]),
                                trailing: Text(
                                    "${o.depense ? '-' : '+'}${o.montant.toStringAsFixed(2)} €",
                                    style: TextStyle(
                                        color: o.depense
                                            ? Colors
                                                .red
                                            : Colors
                                                .green,
                                        fontWeight:
                                            FontWeight
                                                .bold)),
                                onTap: () =>
                                    _dialogRecurrence(
                                        context,
                                        o,
                                        selected),
                              );
                            }))
                  ]),
          ),
        );
      },
    );
  }

  Widget _buildDayCell(DateTime day, Store s, bool isSelected) {
  final hasOps = s.ops.any((o) => o.banque == s.active && o.occursOn(day));
  double soldeJour = s.getSoldeAu(day, false);

  Color textColor = Colors.black;
  if (hasOps) {
    textColor = soldeJour >= 0 ? Colors.green : Colors.red;
  }

  return Stack(
    alignment: Alignment.center,
    children: [
      // 1. Le rond de sélection (centré sur le chiffre)
      if (isSelected)
        Positioned(
          top: 4, 
          child: Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
              color: Color(0x331A237E),
              shape: BoxShape.circle,
            ),
          ),
        ),

      // 2. Le chiffre du jour (Position fixe en haut)
      Positioned(
        top: 10,
        child: Text(
          "${day.day}",
          style: TextStyle(
            color: textColor,
            fontWeight: hasOps ? FontWeight.bold : FontWeight.normal,
            fontSize: 15, // Un peu plus grand pour la lisibilité
          ),
        ),
      ),

      // 3. Le montant (Position fixe en bas, bien séparé)
      if (hasOps)
        Positioned(
          bottom: 4,
          child: Text(
            "${soldeJour.round()}",
            style: TextStyle(
              fontSize: 12, // Augmenté à 12 pour que ce ne soit plus "petit"
              fontWeight: FontWeight.bold,
              color: soldeJour >= 0 ? Colors.green : Colors.red,
            ),
          ),
        ),
    ],
  );
}

  void _addBank() {
    final c = TextEditingController();
    showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text("Nom de la banque"),
              content: TextField(
                  controller: c, autofocus: true),
              actions: [
                ElevatedButton(
                    onPressed: () {
                      if (c.text.isNotEmpty) {
                        Store.I.banques.add(c.text);
                        Store.I.active = c.text;
                        Store.I.save();
                      }
                      Navigator.pop(ctx);
                    },
                    child: const Text("OK"))
              ],
            ));
  }

  void _dialogRecurrence(
      BuildContext context,
      Operation o,
      DateTime selDate) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape:
          const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                  top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding:
              const EdgeInsets.only(bottom: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius:
                          BorderRadius.circular(
                              10))),
              const SizedBox(height: 10),
              ListTile(
                  leading:
                      const Icon(Icons.edit),
                  title: const Text(
                      "Modifier cette occurrence"),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final r = await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                Saisie(
                                    op: o,
                                    dateSelectionnee:
                                        selDate)));
                    if (r != null) {
                      o.exclusions.add(
                          DateFormat('yyyy-MM-dd')
                              .format(selDate));
                      r.id = const Uuid().v4();
                      r.f =
                          Frequence.ponctuel;
                      Store.I.ops.add(r);
                      Store.I.save();
                    }
                  }),
              ListTile(
                  leading: const Icon(
                      Icons.all_inclusive),
                  title: const Text(
                      "Modifier toute la série"),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final r = await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                Saisie(
                                    op: o,
                                    dateSelectionnee:
                                        o.date)));
                    if (r != null) {
                      int idx = Store.I.ops
                          .indexWhere((x) =>
                              x.id == o.id);
                      if (idx != -1) {
                        Store.I.ops[idx] = r;
                      }
                      Store.I.save();
                    }
                  }),
              ListTile(
                  leading: const Icon(
                      Icons.delete_outline),
                  title: const Text(
                      "Supprimer cette occurrence"),
                  onTap: () {
                    o.exclusions.add(
                        DateFormat('yyyy-MM-dd')
                            .format(selDate));
                    Store.I.save();
                    Navigator.pop(ctx);
                  }),
              const Divider(),
              ListTile(
                  leading: const Icon(
                      Icons.delete_forever,
                      color: Colors.red),
                  title: const Text(
                      "Supprimer TOUTE la série",
                      style: TextStyle(
                          color: Colors.red,
                          fontWeight:
                              FontWeight.bold)),
                  onTap: () {
                    Store.I.ops.removeWhere(
                        (x) => x.id == o.id);
                    Store.I.save();
                    Navigator.pop(ctx);
                  }),
            ],
          ),
        ),
      ),
    );
  }
}

class Saisie extends StatefulWidget {
  final Operation? op;
  final DateTime dateSelectionnee;
  const Saisie(
      {super.key,
      this.op,
      required this.dateSelectionnee});
  @override
  State createState() => _Saisie();
}

class _Saisie extends State<Saisie> {
  final d = TextEditingController();
  final m = TextEditingController();
  bool dep = true;
  Frequence fr = Frequence.ponctuel;
  late DateTime dateOp;

  @override
  void initState() {
    super.initState();
    dateOp =
        widget.op?.date ?? widget.dateSelectionnee;
    if (widget.op != null) {
      d.text = widget.op!.desc;
      m.text = widget.op!.montant.toString();
      dep = widget.op!.depense;
      fr = widget.op!.f;
    }
  }

  @override
  Widget build(context) {
    return Scaffold(
      appBar: AppBar(
          backgroundColor: const Color(0xFF1A237E),
          title: Text(widget.op == null
              ? "Nouveau"
              : "Modifier")),
      body: SafeArea(
        child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              TextField(
                  controller: d,
                  decoration:
                      const InputDecoration(
                          labelText:
                              "Description")),
              TextField(
                  controller: m,
                  keyboardType:
                      const TextInputType
                              .numberWithOptions(
                          decimal: true),
                  decoration:
                      const InputDecoration(
                          labelText:
                              "Montant (€)")),
              ListTile(
                  contentPadding:
                      EdgeInsets.zero,
                  leading: const Icon(
                      Icons.calendar_today),
                  title: const Text("Date"),
                  subtitle: Text(DateFormat(
                          'dd/MM/yyyy')
                      .format(dateOp)),
                  onTap: () async {
                    final p = await showDatePicker(
                        context: context,
                        initialDate: dateOp,
                        firstDate:
                            DateTime(2023),
                        lastDate:
                            DateTime(2035),
                        locale:
                            const Locale(
                                "fr", "FR"));
                    if (p != null) {
                      setState(() =>
                          dateOp = p);
                    }
                  }),
              SwitchListTile(
                  title: Text(
                      dep
                          ? "Dépense (Débit)"
                          : "Revenu (Crédit)",
                      style: TextStyle(
                          color: dep
                              ? Colors.red
                              : Colors
                                  .green,
                          fontWeight:
                              FontWeight
                                  .bold)),
                  value: !dep,
                  activeColor: Colors.green,
                  inactiveThumbColor:
                      Colors.red,
                  inactiveTrackColor:
                      Colors.red
                          .withOpacity(0.5),
                  onChanged: (v) =>
                      setState(() =>
                          dep = !v)),
              DropdownButton<Frequence>(
                  isExpanded: true,
                  value: fr,
                  items: Frequence.values
                      .map((e) =>
                          DropdownMenuItem(
                              value: e,
                              child: Text([
                                "Ponctuel",
                                "Quotidien",
                                "Hebdo",
                                "Mensuel",
                                "3 mois",
                                "6 mois",
                                "Annuel"
                              ][e.index])))
                      .toList(),
                  onChanged: (v) =>
                      setState(() =>
                          fr = v!)),
              const Spacer(),
              ElevatedButton(
                  style: ElevatedButton
                      .styleFrom(
                          backgroundColor:
                              const Color(
                                  0xFF1A237E),
                          minimumSize:
                              const Size(
                                  double.infinity,
                                  50)),
                  onPressed: () =>
                      Navigator.pop(
                          context,
                          Operation(
                              id: widget.op?.id ??
                                  const Uuid()
                                      .v4(),
                              desc: d.text,
                              montant: double.tryParse(
                                      m.text
                                          .replaceAll(
                                              ',',
                                              '.')) ??
                                  0,
                              depense: dep,
                              date: dateOp,
                              banque: Store
                                  .I
                                  .active!,
                              f: fr,
  // Si on modifie une op existante, on garde son état (widget.op?.pointer).
  // Si c'est une nouvelle op, on coche (true) si c'est Ponctuel, sinon non (false).
  pointer: widget.op?.pointer ?? (fr == Frequence.ponctuel),
)),
                  child: const Text(
                      "ENREGISTRER",
                      style: TextStyle(
                          color:
                              Colors.white,
                          fontWeight:
                              FontWeight
                                  .bold))),
            ])),
      ),
    );
  }
}

class Recap extends StatefulWidget {
  const Recap({super.key});
  @override
  State createState() => _RecapState();
}

class _RecapState extends State<Recap> {
  DateTime moisAffiche = DateTime.now();

  @override
  Widget build(context) {
    final s = Store.I;
    List<Map<String, dynamic>> occurrencesMois = [];
    DateTime debut = DateTime(moisAffiche.year, moisAffiche.month, 1);
    DateTime fin = DateTime(moisAffiche.year, moisAffiche.month + 1, 0);

    for (DateTime d = debut;
        d.isBefore(fin.add(const Duration(days: 1)));
        d = d.add(const Duration(days: 1))) {
      for (var o in s.ops.where((x) => x.banque == s.active)) {
        if (o.occursOn(d)) {
          occurrencesMois.add({
            'desc': o.desc,
            'montant': o.montant,
            'depense': o.depense
          });
        }
      }
    }

    double revTotal = occurrencesMois
        .where((o) => !o['depense'])
        .fold(0, (p, o) => p + o['montant']);
    double depTotal = occurrencesMois
        .where((o) => o['depense'])
        .fold(0, (p, o) => p + o['montant']);

    return Scaffold(
      appBar: AppBar(
          title: const Text("Récapitulatif"),
          backgroundColor: const Color(0xFF1A237E)),
      body: SafeArea(
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() =>
                    moisAffiche = DateTime(moisAffiche.year, moisAffiche.month - 1))),
            Text(DateFormat('MMMM yyyy', 'fr_FR').format(moisAffiche).toUpperCase(),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() =>
                    moisAffiche = DateTime(moisAffiche.year, moisAffiche.month + 1))),
          ]),
          Card(
              margin: const EdgeInsets.all(12),
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _statCol("REVENUS", revTotal, Colors.green),
                        _statCol("DÉPENSES", depTotal, Colors.red),
                      ]))),
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text("DÉTAILS DU MOIS",
                  style: TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 10))),
          Expanded(
              child: Row(children: [
            // --- COLONNE REVENUS ---
            Expanded(
                child: ListView(
                    children: occurrencesMois
                        .where((o) => !o['depense'])
                        .map((o) => Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), // Interligne réduit
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                      child: Text(o['desc'],
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 13))), // Texte agrandi
                                  Text("${o['montant'].toStringAsFixed(2)}€",
                                      style: const TextStyle(
                                          color: Colors.green,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12)),
                                ],
                              ),
                            ))
                        .toList())),
            const VerticalDivider(width: 1),
            // --- COLONNE DÉPENSES ---
            Expanded(
                child: ListView(
                    children: occurrencesMois
                        .where((o) => o['depense'])
                        .map((o) => Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), // Interligne réduit
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                      child: Text(o['desc'],
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 13))), // Texte agrandi
                                  Text("${o['montant'].toStringAsFixed(2)}€",
                                      style: const TextStyle(
                                          color: Colors.red,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12)),
                                ],
                              ),
                            ))
                        .toList())),
          ])),
        ]),
      ),
    );
  }

  Widget _statCol(String t, double v, Color c) => Column(children: [
        Text(t, style: const TextStyle(fontSize: 10)),
        Text("${v.toStringAsFixed(2)} €",
            style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: 18))
      ]);
}

class Parametres extends StatefulWidget {
  const Parametres({super.key});
  @override
  State<Parametres> createState() => _ParametresState();
}

class _ParametresState extends State<Parametres> {
  @override
  Widget build(BuildContext context) {
    final s = Store.I;
    return Scaffold(
      appBar: AppBar(
        title: const Text("Paramètres"),
        backgroundColor: const Color(0xFF1A237E),
      ),
      body: SafeArea(
        child: ListView(
          children: [
            // 1. POINTER LE PASSÉ -> Sort après clic
            ListTile(
              leading: const Icon(Icons.done_all, color: Colors.blue),
              title: const Text("Pointer le passé"),
              subtitle: const Text("Marque tout comme payé avant aujourd'hui"),
              onTap: () {
                setState(() {
                  for (var o in s.ops.where((x) =>
                      x.banque == s.active &&
                      x.date.isBefore(DateTime.now()))) {
                    o.pointer = true;
                  }
                  s.save();
                });
                Navigator.pop(context); // Retour aux comptes
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Opérations passées pointées !")),
                );
              },
            ),
            
            // 2. AJUSTER LE SOLDE -> Sort après validation
            ListTile(
              leading: const Icon(Icons.account_balance_wallet, color: Colors.indigo),
              title: const Text("Ajuster le solde"),
              subtitle: const Text("Corriger le montant actuel"),
              onTap: () => _showAjusterSolde(context),
            ),
            
            const Divider(),

            // 3. EXPORTER (BACKUP) -> Reste ici car on attend souvent le menu de partage
            ListTile(
              leading: const Icon(Icons.download, color: Colors.orange),
              title: const Text("Exporter (Backup)"),
              onTap: () async {
                Map<String, dynamic> fullBackup = {
                  "banques": s.banques,
                  "active": s.active,
                  "ops": s.ops.map((e) => e.toMap()).toList(),
                };
                String data = jsonEncode(fullBackup);
                final xfile = XFile.fromData(
                  utf8.encode(data),
                  name: 'backup.json',
                  mimeType: 'application/json',
                );
                await Share.shareXFiles([xfile]);
              },
            ),

            // 4. IMPORTER (RESTAURER) -> Sort après sélection du fichier
            ListTile(
              leading: const Icon(Icons.upload, color: Colors.deepPurple),
              title: const Text("Importer (Restaurer)"),
              onTap: () async {
                try {
                  FilePickerResult? result = await FilePicker.platform.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: ['json'],
                  );

                  if (result != null) {
                    final content = result.files.single.bytes != null 
                      ? utf8.decode(result.files.single.bytes!) 
                      : await File(result.files.single.path!).readAsString();
                    
                    Map data = jsonDecode(content);
                    setState(() {
                      s.banques = List<String>.from(data["banques"] ?? []);
                      s.active = data["active"];
                      s.ops = (data["ops"] as List).map((e) => Operation.fromMap(e)).toList();
                      s.save();
                    });

                    if (mounted) {
                      Navigator.pop(context); // Retour aux comptes
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Restauration réussie !")),
                      );
                    }
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Erreur d'import : $e")),
                    );
                  }
                }
              },
            ),

            const Divider(),

            // 5. AJOUTER UNE BANQUE -> Sort après OK
            ListTile(
              leading: const Icon(Icons.add_to_home_screen, color: Colors.green),
              title: const Text("Ajouter une banque"),
              onTap: () => _addBank(context),
            ),

            // 6. SUPPRIMER LA BANQUE -> Sort après OUI
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: const Text("Supprimer la banque actuelle"),
              onTap: () {
                if (s.active == null) return;
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text("Supprimer ?"),
                    content: Text("Voulez-vous vraiment supprimer ${s.active} ?"),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("NON")),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            s.ops.removeWhere((o) => o.banque == s.active);
                            s.banques.remove(s.active);
                            s.active = s.banques.isNotEmpty ? s.banques.first : null;
                            s.save();
                          });
                          Navigator.pop(ctx); // Ferme dialogue
                          Navigator.pop(context); // Retour aux comptes
                        },
                        child: const Text("OUI"),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _addBank(BuildContext context) {
    final c = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Nom de la banque"),
        content: TextField(controller: c, autofocus: true),
        actions: [
          ElevatedButton(
            onPressed: () {
              if (c.text.isNotEmpty) {
                setState(() {
                  Store.I.banques.add(c.text);
                  Store.I.active = c.text;
                  Store.I.save();
                });
                Navigator.pop(ctx); // Ferme dialogue
                Navigator.pop(context); // Retour aux comptes
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Banque ajoutée !")),
                );
              }
            },
            child: const Text("OK"),
          )
        ],
      ),
    );
  }

  void _showAjusterSolde(BuildContext context) {
    final c = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Ajuster le solde"),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: "Nouveau solde voulu (€)"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("ANNULER")),
          ElevatedButton(
            onPressed: () {
              double? nv = double.tryParse(c.text.replaceAll(',', '.'));
              if (nv != null) {
                double diff = nv - Store.I.getSoldeAu(DateTime.now(), false);
                if (diff != 0) {
                  setState(() {
                    Store.I.ops.add(Operation(
                      id: const Uuid().v4(),
                      desc: "Ajustement",
                      montant: diff.abs(),
                      depense: diff < 0,
                      date: DateTime.now(),
                      banque: Store.I.active!,
                      f: Frequence.ponctuel,
                      pointer: true,
                    ));
                    Store.I.save();
                  });
                }
                Navigator.pop(ctx); // Ferme dialogue
                Navigator.pop(context); // Retour aux comptes
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Solde mis à jour !")),
                );
              }
            },
            child: const Text("VALIDER"),
          )
        ],
      ),
    );
  }
}