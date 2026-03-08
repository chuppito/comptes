import 'dart:convert';                          // Pour encoder/décoder JSON (export/import)
import 'dart:io';                               // Pour lire les fichiers sur le système
import 'package:flutter/material.dart';         // Widgets matériels de base
import 'package:flutter_localizations/flutter_localizations.dart'; // Localisation Flutter
import 'package:hive_flutter/hive_flutter.dart'; // Stockage local clé/valeur
import 'package:intl/date_symbol_data_local.dart'; // Formats de date localisés
import 'package:intl/intl.dart';               // Formatage de dates/nombres
import 'package:table_calendar/table_calendar.dart'; // Calendrier interactif
import 'package:uuid/uuid.dart';               // Génération d'UUID pour les opérations
import 'package:share_plus/share_plus.dart';   // Partage de fichiers (backup JSON)
import 'package:file_picker/file_picker.dart'; // Choisir un fichier (import JSON)
import 'dart:async'; // Obligatoire pour StreamSubscription (écoute des liens)
import 'package:app_links/app_links.dart';     // Deep links (utilisé avec Macrodroid)

void main() async {
  WidgetsFlutterBinding.ensureInitialized();    // IMPORTANT : permet d’utiliser du code async avant runApp
  await initializeDateFormatting('fr_FR', null); // Initialise les formats de date en français
  await Hive.initFlutter();                    // Initialise Hive dans le contexte Flutter
  await Hive.openBox("db");                    // Ouvre/Crée la box de stockage "db"
  runApp(const App());                         // Lance l’application Flutter
}

// Fréquences possibles pour les opérations récurrentes
enum Frequence { ponctuel, jour, semaine, mois, trimestre, semestre, an }

// Modèle de données principal : une opération bancaire (débit/crédit)
class Operation {
  String id;             // Identifiant unique (UUID)
  String desc;           // Description (libellé)
  double montant;        // Montant en euros
  bool depense;          // true = dépense (débit), false = revenu (crédit)
  bool pointer;          // true = déjà pointé (payé), false = en attente
  DateTime date;         // Date de départ de l’opération (pour la récurrence)
  String banque;         // Banque à laquelle appartient l’opération
  Frequence f;           // Fréquence de récurrence
  List<String> exclusions; // Dates à exclure pour les séries (format "yyyy-MM-dd")

  Operation({
    required this.id,
    required this.desc,
    required this.montant,
    required this.depense,
    required this.date,
    required this.banque,
    this.pointer = false,                // Par défaut non pointé
    this.f = Frequence.ponctuel,         // Par défaut ponctuel (non récurrent)
    List<String>? exclusions,            // Optionnel : liste de dates exclues
  }) : exclusions = exclusions ?? [];

  // Conversion en Map pour stockage dans Hive (clés raccourcies pour économiser de la place)
  Map toMap() => {
        "id": id,
        "d": desc,
        "m": montant,
        "dep": depense,
        "p": pointer,
        "dt": date.toIso8601String(),
        "b": banque,
        "f": f.index,        // On stocke l’index de l’enum
        "ex": exclusions,
      };

  // Reconstruction d'une Operation depuis les données persistées
  factory Operation.fromMap(Map m) => Operation(
        id: m["id"],
        desc: m["d"],
        montant: (m["m"]).toDouble(),
        depense: m["dep"],
        pointer: m["p"] ?? false,
        date: DateTime.parse(m["dt"]),
        banque: m["b"],
        f: Frequence.values[m["f"]],                    // On récupère l’enum via son index
        exclusions: m["ex"] != null ? List<String>.from(m["ex"]) : [],
      );

  // Indique si l’opération (récurrente ou non) doit apparaître à une date donnée
  bool occursOn(DateTime day) {
    // 1) Si la date est explicitement exclue -> ne pas afficher
    if (exclusions.contains(DateFormat('yyyy-MM-dd').format(day))) {
      return false;
    }

    // 2) Si la date de départ est après le jour testé (et différent) -> la série n’a pas encore commencé
    if (date.isAfter(day) && !isSameDay(date, day)) {
      return false;
    }

    // 3) Logique de récurrence en fonction de f
    switch (f) {
      case Frequence.ponctuel:
        // Une seule fois, à la date exacte
        return isSameDay(date, day);
      case Frequence.jour:
        // Tous les jours à partir de "date"
        return true;
      case Frequence.semaine:
        // Tous les jours de semaine identiques (lundi, mardi, etc.)
        return date.weekday == day.weekday;
      case Frequence.mois:
        // Tous les mois, même jour du mois (ex: le 5)
        return date.day == day.day;
      case Frequence.trimestre:
        // Tous les 3 mois, même jour du mois
        return date.day == day.day &&
            ((day.year - date.year) * 12 + day.month - date.month) % 3 == 0;
      case Frequence.semestre:
        // Tous les 6 mois, même jour du mois
        return date.day == day.day &&
            ((day.year - date.year) * 12 + day.month - date.month) % 6 == 0;
      case Frequence.an:
        // Tous les ans, même jour + même mois
        return date.day == day.day && date.month == day.month;
    }
  }
}

/// ========= STORE OPTIMISÉ AVEC CACHE =========
/// Gère toutes les données (banques, opérations) + calcul des soldes.
/// Utilise un cache pour éviter de recalculer les soldes à chaque fois.
class Store extends ChangeNotifier {
  static final I = Store._();      // Singleton (Store.I partout dans l’app)

  Store._() {
    load();                        // Charge les données dès l’instanciation
  }

  final box = Hive.box("db");      // Box Hive pour persistance

  List<String> banques = [];       // Liste des noms de banques
  String? active;                  // Banque actuellement sélectionnée
  List<Operation> ops = [];        // Liste de toutes les opérations (toutes banques)

  // Cache des soldes par banque : { "banque" : { date => solde } }
  final Map<String, Map<DateTime, double>> _cacheSoldesParBanque = {};

  // Récupère (ou crée) le cache pour la banque active
  Map<DateTime, double> _cacheForActive() {
    if (active == null) return {};
    return _cacheSoldesParBanque.putIfAbsent(active!, () => {});
  }

  // Invalide complètement tous les caches (appelé après save/load)
  void _clearCache() {
    _cacheSoldesParBanque.clear();
  }

  // Chargement des données depuis Hive
  void load() {
    banques = (box.get("banques") ?? []).cast<String>(); // Liste de banques
    active = box.get("active");                          // Banque active
    final raw = box.get("ops");                          // Liste brute d’ops
    if (raw != null) {
      ops = List.from(raw)
          .map((e) => Operation.fromMap(Map.from(e)))
          .toList();
    }
    _clearCache();                                       // On repart sur un cache propre
    notifyListeners();                                   // Notifie les widgets (AnimatedBuilder, etc.)
  }

  // Sauvegarde complète dans Hive
  void save() {
    box.put("banques", banques);
    box.put("active", active);
    box.put("ops", ops.map((e) => e.toMap()).toList());
    _clearCache();                                       // Toute modif invalide le cache
    notifyListeners();
  }

  // Calcule le solde (théorique ou pointé) d’une banque active à une date donnée
  double getSoldeAu(DateTime dateCible, bool seulementPointe) {
    if (active == null) return 0;

    final cache = _cacheForActive();

    // On n’utilise que l’année/mois/jour (heure ignorée)
    DateTime cible = DateTime(dateCible.year, dateCible.month, dateCible.day);

    // Si un solde est déjà en cache pour cette date (et qu’on ne filtre pas sur "pointé") -> retour direct
    if (cache.containsKey(cible) && !seulementPointe) {
      return cache[cible]!;
    }

    // Date de départ pour le calcul des soldes (peut être ajustée)
    DateTime base = DateTime(2023, 1, 1);

    double total;
    DateTime curseur;

    // Si on a déjà un cache et qu’on ne filtre pas sur "pointé"
    if (!seulementPointe && cache.isNotEmpty) {
      // On retrouve la dernière date pour laquelle on a un solde en cache
      DateTime lastCachedDate =
          cache.keys.reduce((a, b) => a.isAfter(b) ? a : b);

      if (lastCachedDate.isAfter(cible)) {
        // Cas rare : si la dernière date en cache est après la cible -> on repart depuis le début
        total = 0;
        curseur = base;
        cache.clear();
      } else {
        // Sinon on repart de la dernière date en cache (gain de perf)
        total = cache[lastCachedDate]!;
        curseur = lastCachedDate.add(const Duration(days: 1));
      }
    } else {
      // Pas de cache exploitable ou bien on veut "seulementPointe"
      total = 0;
      curseur = base;
      if (!seulementPointe) cache.clear(); // On reset le cache si on recalcule tout
    }

    // Boucle du "base" (ou lastCachedDate) jusqu’à la date cible incluse
    while (curseur.isBefore(cible) || isSameDay(curseur, cible)) {
      // On parcourt toutes les opérations de la banque active
      for (var o in ops.where((x) => x.banque == active)) {
        if (o.occursOn(curseur)) {
          // Si on ne veut que les opérations pointées, on vérifie o.pointer
          if (!seulementPointe || o.pointer) {
            total += o.depense ? -o.montant : o.montant;
          }
        }
      }
      // Si on calcule le solde théorique (pas filtré sur pointé), on enregistre dans le cache
      if (!seulementPointe) {
        cache[DateTime(curseur.year, curseur.month, curseur.day)] = total;
      }
      // Jour suivant
      curseur = curseur.add(const Duration(days: 1));
    }

    return total;
  }
}
/// ============================================

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(context) => MaterialApp(
        debugShowCheckedModeBanner: false,           // Enlève le bandeau "Debug"
        theme: ThemeData(
            primarySwatch: Colors.indigo,            // Couleur principale
            useMaterial3: false),                    // Utiliser la vieille API Material (M2)
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate
        ],
        supportedLocales: const [
          Locale('fr', 'FR')                         // Seule langue : français
        ],
        locale: const Locale('fr', 'FR'),
        home: const Home(),                          // Écran d’accueil
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State createState() => _Home();
}

class _Home extends State<Home> {
  DateTime focus = DateTime.now();      // Jour actuellement centré dans le calendrier
  DateTime selected = DateTime.now();   // Jour sélectionné par l’utilisateur

  // --- LOGIQUE RÉCEPTION LIENS (MACRODROID) ---
  late AppLinks _appLinks;              // Gestionnaire de deep links
  StreamSubscription<Uri>? _linkSubscription; // Abonnement au flux des liens entrants

  @override
  void initState() {
    super.initState();
    _initDeepLinks();                   // Mise en place des deep links au démarrage
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();        // On annule l’abonnement pour éviter les fuites mémoire
    super.dispose();
  }

  // Initialisation du plugin AppLinks (deep links)
  void _initDeepLinks() async {
    _appLinks = AppLinks();             // Instanciation

    // Écoute des liens reçus pendant que l’app est déjà ouverte
    _linkSubscription =
        _appLinks.uriLinkStream.listen((uri) => _handleDeepLink(uri));

    try {
      // Récupère un éventuel lien qui a lancé l’app (cas d’ouverture à partir d’un deep link)
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) _handleDeepLink(initialUri);
    } catch (e) {
      debugPrint("Erreur lien: $e");
    }
  }

  // Traitement d’un deep link, par ex. :
  // mesfinances://ajout?banque=BNP&montant=15,20&desc=McDo
  // ou   mesfinances://ajout?banque=BNP&credit=1000&desc=Salaire
  void _handleDeepLink(Uri uri) {
    if (uri.scheme == 'mesfinances' && uri.host == 'ajout') {
      final s = Store.I;

      // Extraction et distinction débit/crédit :
      //  - "montant" => dépense
      //  - "credit"  => revenu
      final String? debitStr =
          uri.queryParameters['montant']?.replaceAll(',', '.');
      final String? creditStr =
          uri.queryParameters['credit']?.replaceAll(',', '.');
      final bool isCredit = uri.queryParameters.containsKey('credit');
      final String? mStr = isCredit ? creditStr : debitStr;

      final m = double.tryParse(mStr ?? '0');               // Montant parsé
      final d = uri.queryParameters['desc'] ?? 'Achat Mobile'; // Description par défaut
      final b = uri.queryParameters['banque'];              // Banque visée

      // Conditions minimales pour créer l’opération
      if (m != null && m > 0 && b != null && s.banques.contains(b)) {
        setState(() {
          s.ops.add(Operation(
            id: const Uuid().v4(),                          // Nouveau UUID
            desc: d,
            montant: m,
            depense: isCredit ? false : true,               // crédit = revenu
            date: DateTime.now(),                           // Date du jour
            banque: b,
            f: Frequence.ponctuel,                          // Ajout Macrodroid = ponctuel
            pointer: true,                                  // Directement pointé
          ));
          s.save();
        });
        if (mounted) {
          // Snackbar de confirmation
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
    final s = Store.I;          // Raccourci

    return AnimatedBuilder(
      animation: s,             // Se rebuild dès que Store.notifyListeners() est appelé
      builder: (c, _) {
        // Opérations du jour sélectionné pour la banque active
        final currentOps = s.ops
            .where((o) => o.banque == s.active && o.occursOn(selected))
            .toList();

        // Solde théorique / solde pointé au jour sélectionné
        double soldeTotal = s.getSoldeAu(selected, false);
        double soldePointe = s.getSoldeAu(selected, true);

        return Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF1A237E),
            title: s.active == null
                ? const Text("Mes Comptes")
                : PopupMenuButton<String>(
                    // Menu déroulant pour choisir la banque active
                    onSelected: (v) {
                      setState(() {
                        s.active = v;
                        s.save();
                      });
                    },
                    itemBuilder: (ctx) => s.banques
                        .map((b) =>
                            PopupMenuItem(value: b, child: Text(b)))
                        .toList(),
                    child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(s.active!),
                          const Icon(Icons.arrow_drop_down)
                        ]),
                  ),
            actions: [
              // 1. Ajouter une opération (ouvre l’écran Saisie)
              if (s.active != null)
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 28),
                  onPressed: () async {
                    final r = await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                Saisie(dateSelectionnee: selected)));
                    if (r != null) {
                      setState(() {
                        s.ops.add(r);
                        s.save();
                      });
                    }
                  },
                ),

              // 2. Accès à l’écran de récapitulatif mensuel
              if (s.active != null)
                IconButton(
                    icon: const Icon(Icons.bar_chart),
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const Recap()))),

              // 3. Accès aux paramètres
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
                // Cas où aucune banque n’existe encore : bouton pour en créer une
                ? Center(
                    child: ElevatedButton(
                        onPressed: _addBank,
                        child: const Text("Ajouter une banque")))
                : Column(children: [
                    // Calendrier principal
                    TableCalendar(
                      locale: "fr_FR",
                      firstDay: DateTime.utc(2023),
                      lastDay: DateTime.utc(2035),
                      focusedDay: focus,
                      startingDayOfWeek: StartingDayOfWeek.monday,
                      rowHeight: 62,
                      selectedDayPredicate: (d) => isSameDay(d, selected),
                      onDaySelected: (d, f) => setState(() {
                        selected = d;
                        focus = f;
                      }),
                      headerStyle: const HeaderStyle(
                          formatButtonVisible: false,
                          titleCentered: true),
                      calendarBuilders: CalendarBuilders(
                        // Cellule par défaut
                        defaultBuilder: (context, day, focusedDay) {
                          return _buildDayCell(day, s, false);
                        },
                        // Cellule sélectionnée
                        selectedBuilder: (context, day, focusedDay) {
                          return _buildDayCell(day, s, true);
                        },
                        // Jours en dehors du mois en cours : affichés en gris
                        outsideBuilder: (context, day, focusedDay) {
                          return Opacity(
                            opacity: 0.5,
                            child: _buildDayCell(day, s, false),
                          );
                        },
                        // Pas de marqueurs d’événements supplémentaires
                        markerBuilder: (context, day, events) {
                          return const SizedBox.shrink();
                        },
                      ),
                    ),

                    // Affichage du solde pour la date sélectionnée
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: 10),
                      child: Column(children: [
                        Text(
                            "Solde au ${DateFormat('dd MMMM yyyy', 'fr_FR').format(selected)}",
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 12)),
                        const SizedBox(height: 4),
                        Row(
                            mainAxisAlignment:
                                MainAxisAlignment.center,
                            children: [
                              // Solde global (toutes opérations, pointées ou non)
                              Text(
                                  "${soldeTotal.toStringAsFixed(2)} €",
                                  style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      color: soldeTotal >= 0
                                          ? Colors.green
                                          : Colors.red)),
                              const SizedBox(width: 8),
                              // Solde pointé uniquement (✓)
                              Text(
                                  "(✓ ${soldePointe.toStringAsFixed(2)} €)",
                                  style: const TextStyle(
                                      fontSize: 16,
                                      color: Colors.green,
                                      fontWeight:
                                          FontWeight.w500)),
                            ]),
                      ]),
                    ),

                    // Liste des opérations du jour sélectionné
                    Expanded(
                        child: ListView.builder(
                            itemCount: currentOps.length,
                            itemBuilder: (c, i) {
                              final o = currentOps[i];
                              return ListTile(
                                // Case à cocher pour pointer/dépointer
                                leading: Checkbox(
                                    value: o.pointer,
                                    activeColor: Colors.indigo,
                                    onChanged: (v) {
                                      setState(() {
                                        o.pointer = v!;
                                        Store.I.save();
                                      });
                                    }),
                                title: Text(o.desc,
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight.w500)),
                                // Indication de la fréquence si ce n’est pas ponctuel
                                subtitle: o.f ==
                                        Frequence.ponctuel
                                    ? null
                                    : Row(children: [
                                        const Icon(
                                            Icons.refresh,
                                            size: 12,
                                            color: Colors.grey),
                                        const SizedBox(
                                            width: 4),
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
                                                fontSize: 10,
                                                color:
                                                    Colors.grey))
                                      ]),
                                // Montant avec signe et couleur
                                trailing: Text(
                                    "${o.depense ? '-' : '+'}${o.montant.toStringAsFixed(2)} €",
                                    style: TextStyle(
                                        color: o.depense
                                            ? Colors.red
                                            : Colors.green,
                                        fontWeight:
                                            FontWeight.bold)),
                                // Tap = ouvrir le menu de gestion de la récurrence
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

  // Construit l’affichage d’une cellule de jour dans le calendrier
  Widget _buildDayCell(DateTime day, Store s, bool isSelected) {
    final hasOps =
        s.ops.any((o) => o.banque == s.active && o.occursOn(day)); // Y a-t-il des opérations ce jour ?
    double soldeJour = s.getSoldeAu(day, false);                   // Solde cumulé à ce jour

    Color textColor = Colors.black;
    if (hasOps) {
      // Si des opérations existent ce jour, couleur verte/rouge selon solde
      textColor = soldeJour >= 0 ? Colors.green : Colors.red;
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        // 1. Rond de sélection en fond si le jour est sélectionné
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

        // 2. Numéro du jour (en haut)
        Positioned(
          top: 10,
          child: Text(
            "${day.day}",
            style: TextStyle(
              color: textColor,
              fontWeight:
                  hasOps ? FontWeight.bold : FontWeight.normal,
              fontSize: 15,
            ),
          ),
        ),

        // 3. Solde du jour affiché en bas (arrondi), si au moins une opération
        if (hasOps)
          Positioned(
            bottom: 4,
            child: Text(
              "${soldeJour.round()}",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: soldeJour >= 0 ? Colors.green : Colors.red,
              ),
            ),
          ),
      ],
    );
  }

  // Dialog d’ajout de banque depuis l’écran principal
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

  // Feuille du bas pour gérer une occurrence d’une série récurrente
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
              // Petite barre "drag handle"
              Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius:
                          BorderRadius.circular(
                              10))),
              const SizedBox(height: 10),

              // Modifier uniquement cette occurrence (cloner en ponctuel + exclure cette date)
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
                      // On exclut la date de l’ancienne série...
                      o.exclusions.add(
                          DateFormat('yyyy-MM-dd')
                              .format(selDate));
                      // ...et on ajoute une nouvelle opération ponctuelle pour cette date
                      r.id = const Uuid().v4();
                      r.f =
                          Frequence.ponctuel;
                      Store.I.ops.add(r);
                      Store.I.save();
                    }
                  }),

              // Modifier toute la série (remplace l’opération d’origine)
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

              // Supprimer seulement cette occurrence (on ajoute la date aux exclusions)
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

              // Supprimer toute la série (supprime l’opération elle-même)
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

// Écran de saisie / édition d’une opération
class Saisie extends StatefulWidget {
  final Operation? op;                // null = nouvelle opération, non null = édition
  final DateTime dateSelectionnee;    // Date par défaut si nouvelle opération
  const Saisie(
      {super.key,
      this.op,
      required this.dateSelectionnee});
  @override
  State createState() => _Saisie();
}

class _Saisie extends State<Saisie> {
  final d = TextEditingController();  // Description
  final m = TextEditingController();  // Montant
  bool dep = true;                    // true = dépense
  Frequence fr = Frequence.ponctuel;  // Fréquence
  late DateTime dateOp;              // Date de l’opération

  @override
  void initState() {
    super.initState();
    // Date initiale : celle de l’op (en édition) ou la date sélectionnée sur le calendrier
    dateOp =
        widget.op?.date ?? widget.dateSelectionnee;

    // Si on édite une opération existante, on pré-remplit les champs
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
              // Champ description
              TextField(
                  controller: d,
                  decoration:
                      const InputDecoration(
                          labelText:
                              "Description")),
              // Champ montant
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
              // Sélection de la date via un DatePicker
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
              // Switch Dépense / Revenu
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
                  activeThumbColor: Colors.green,
                  inactiveThumbColor:
                      Colors.red,
                  inactiveTrackColor:
                      Colors.red
                          .withValues(alpha: 0.5),
                  onChanged: (v) =>
                      setState(() =>
                          dep = !v)),
              // Choix de la fréquence de récurrence
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
              // Bouton ENREGISTRER -> renvoie une Operation au caller (Home ou Recap, etc.)
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

// Écran de récapitulatif mensuel
class Recap extends StatefulWidget {
  const Recap({super.key});
  @override
  State createState() => _RecapState();
}

class _RecapState extends State<Recap> {
  DateTime moisAffiche = DateTime.now();  // Mois actuellement affiché

  @override
  Widget build(context) {
    final s = Store.I;
    List<Map<String, dynamic>> occurrencesMois = []; // Liste des occurrences (dépliage des récurrences)

    // 1er et dernier jour du mois
    DateTime debut = DateTime(moisAffiche.year, moisAffiche.month, 1);
    DateTime fin = DateTime(moisAffiche.year, moisAffiche.month + 1, 0);

    // On parcourt tous les jours du mois...
    for (DateTime d = debut;
        d.isBefore(fin.add(const Duration(days: 1)));
        d = d.add(const Duration(days: 1))) {
      // ...et pour chaque jour, toutes les opérations de la banque active
      for (var o in s.ops.where((x) => x.banque == s.active)) {
        if (o.occursOn(d)) {
          // On ajoute une "occurrence" de cette op pour ce jour
          occurrencesMois.add({
            'desc': o.desc,
            'montant': o.montant,
            'depense': o.depense
          });
        }
      }
    }

    // Somme des revenus du mois
    double revTotal = occurrencesMois
        .where((o) => !o['depense'])
        .fold(0, (p, o) => p + o['montant']);

    // Somme des dépenses du mois
    double depTotal = occurrencesMois
        .where((o) => o['depense'])
        .fold(0, (p, o) => p + o['montant']);

    return Scaffold(
      appBar: AppBar(
          title: const Text("Récapitulatif"),
          backgroundColor: const Color(0xFF1A237E)),
      body: SafeArea(
        child: Column(children: [
          // Bandeau haut avec navigation mois précédent / suivant
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() =>
                    moisAffiche = DateTime(
                        moisAffiche.year,
                        moisAffiche.month - 1))),
            Text(
                DateFormat('MMMM yyyy', 'fr_FR')
                    .format(moisAffiche)
                    .toUpperCase(),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16)),
            IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() =>
                    moisAffiche = DateTime(
                        moisAffiche.year,
                        moisAffiche.month + 1))),
          ]),

          // Carte avec totaux revenus / dépenses
          Card(
              margin: const EdgeInsets.all(12),
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceAround,
                      children: [
                        _statCol("REVENUS", revTotal, Colors.green),
                        _statCol("DÉPENSES", depTotal, Colors.red),
                      ]))),

          const Padding(
              padding:
                  EdgeInsets.symmetric(vertical: 8),
              child: Text("DÉTAILS DU MOIS",
                  style: TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 10))),

          // Deux colonnes : à gauche revenus, à droite dépenses
          Expanded(
              child: Row(children: [
            // --- COLONNE REVENUS ---
            Expanded(
                child: ListView(
                    children: occurrencesMois
                        .where((o) => !o['depense'])
                        .map((o) => Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                      child: Text(o['desc'],
                                          overflow:
                                              TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 13))),
                                  Text(
                                      "${o['montant'].toStringAsFixed(2)}€",
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
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                      child: Text(o['desc'],
                                          overflow:
                                              TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 13))),
                                  Text(
                                      "${o['montant'].toStringAsFixed(2)}€",
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

  // Colonne stat (titre + valeur colorée)
  Widget _statCol(String t, double v, Color c) =>
      Column(children: [
        Text(t, style: const TextStyle(fontSize: 10)),
        Text("${v.toStringAsFixed(2)} €",
            style: TextStyle(
                color: c,
                fontWeight: FontWeight.bold,
                fontSize: 18))
      ]);
}

// Écran de paramètres : actions globales (pointer passé, ajuster solde, backup, etc.)
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
            // 1. POINTER LE PASSÉ -> marque tout comme payé avant aujourd’hui
            ListTile(
              leading:
                  const Icon(Icons.done_all, color: Colors.blue),
              title: const Text("Pointer le passé"),
              subtitle: const Text(
                  "Marque tout comme payé avant aujourd'hui"),
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
                  const SnackBar(
                      content:
                          Text("Opérations passées pointées !")),
                );
              },
            ),

            // 2. AJUSTER LE SOLDE -> crée une op "Ajustement" pour arriver au solde voulu
            ListTile(
              leading: const Icon(
                  Icons.account_balance_wallet,
                  color: Colors.indigo),
              title: const Text("Ajuster le solde"),
              subtitle: const Text("Corriger le montant actuel"),
              onTap: () => _showAjusterSolde(context),
            ),

            const Divider(),

            // 3. EXPORTER (BACKUP) -> Génère un JSON complet et ouvre la feuille de partage
            ListTile(
              leading: const Icon(Icons.download,
                  color: Colors.orange),
              title: const Text("Exporter (Backup)"),
              onTap: () async {
                // Construire le JSON complet : banques + active + ops
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

            // 4. IMPORTER (RESTAURER)
ListTile(
  leading: const Icon(Icons.upload, color: Colors.deepPurple),
  title: const Text("Importer (Restaurer)"),
  onTap: () async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result == null) return; // L'utilisateur a annulé

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

      // On vérifie la sécurité
      if (!mounted) return;

      // Solution : On récupère les instances via Navigator.of et ScaffoldMessenger.of
      // Cela rassure le linter car on "consomme" le context immédiatement après le check
      Navigator.of(context).pop(); 
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Restauration réussie !")),
      );
    } catch (e) {
      // Sécurité également dans le catch
      if (!mounted) return; 

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur d'import : $e")),
      );
    }
  },
),

            const Divider(),

            // 5. AJOUTER UNE BANQUE depuis l’écran paramètres
            ListTile(
              leading: const Icon(Icons.add_to_home_screen,
                  color: Colors.green),
              title: const Text("Ajouter une banque"),
              onTap: () => _addBank(context),
            ),

            // 6. SUPPRIMER LA BANQUE ACTUELLE (et toutes ses opérations)
            ListTile(
              leading: const Icon(Icons.delete_forever,
                  color: Colors.red),
              title: const Text(
                  "Supprimer la banque actuelle"),
              onTap: () {
                if (s.active == null) return;
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text("Supprimer ?"),
                    content: Text(
                        "Voulez-vous vraiment supprimer ${s.active} ?"),
                    actions: [
                      TextButton(
                          onPressed: () =>
                              Navigator.pop(ctx),
                          child: const Text("NON")),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            // Supprime toutes les opérations de la banque
                            s.ops.removeWhere(
                                (o) => o.banque == s.active);
                            // Supprime la banque de la liste
                            s.banques.remove(s.active);
                            // Re-détermine la banque active
                            s.active = s.banques.isNotEmpty
                                ? s.banques.first
                                : null;
                            s.save();
                          });
                          Navigator.pop(
                              ctx); // Ferme le dialogue
                          Navigator.pop(
                              context); // Retour aux comptes
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

  // Ajout d’une banque depuis l’écran Paramètres (version avec snackbars)
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
                  const SnackBar(
                      content: Text("Banque ajoutée !")),
                );
              }
            },
            child: const Text("OK"),
          )
        ],
      ),
    );
  }

  // Dialog d’ajustement de solde : crée une op "Ajustement" pour corriger le solde actuel
  void _showAjusterSolde(BuildContext context) {
    final c = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Ajuster le solde"),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: "Nouveau solde voulu (€)"),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("ANNULER")),
          ElevatedButton(
            onPressed: () {
              double? nv = double.tryParse(
                  c.text.replaceAll(',', '.'));
              if (nv != null) {
                // On calcule la différence entre le solde voulu et le solde actuel
                double diff = nv -
                    Store.I.getSoldeAu(
                        DateTime.now(), false);
                if (diff != 0) {
                  setState(() {
                    // On ajoute une opération "Ajustement" qui corrige le solde
                    Store.I.ops.add(Operation(
                      id: const Uuid().v4(),
                      desc: "Ajustement",
                      montant: diff.abs(),
                      depense: diff < 0, // Si diff<0, on doit diminuer -> dépense
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
                  const SnackBar(
                      content:
                          Text("Solde mis à jour !")),
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
