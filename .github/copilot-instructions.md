# Copilot Instructions for Comptes

## Project Overview
**Comptes** is a multi-platform Flutter application for managing personal bank accounts and transactions with recurring payment support. The app uses calendar-based navigation and is entirely French-localized.

## Architecture & Key Components

### Single-File Monolithic Structure
All code lives in [lib/main.dart](../../lib/main.dart). The app has three main components:

1. **`Operation` Model** - Core data structure with:
   - Serialization via `toMap()`/`fromMap()` for JSON persistence
   - Frequency field: "Ponctuel" (one-time), "Tous les jours" (daily), "Tous les mois" (monthly), "Tous les 3 mois" (quarterly), "Tous les 6 mois" (biannual), "Tous les ans" (annual)
   - Bank assignment (`banque` field) for multi-bank support

2. **`EcranPrincipal` (Main Screen)** - Home screen controller:
   - Calendar view with TableCalendar (French locale)
   - Transaction display filtered by selected date and active bank
   - Balance calculation via `_soldeTotal` getter (sum of expenses as negative)
   - Bank switching via FAB action
   - Long-press to delete transactions

3. **`EcranSaisie` (Entry Screen)** - Transaction form:
   - Text input: description, amount
   - Toggle: expense vs income
   - Dropdown: frequency selection
   - Returns Operation object via Navigator.pop()

### State Management Pattern
Uses **StatefulWidget with setState** throughout. No external state management (Riverpod, Provider, etc.):
- `_toutesLesOps` - master list of all operations
- `_mesBanques` - list of user-created banks
- `_banqueActive` - currently selected bank
- `_selectedDay` / `_focusedDay` - calendar state

### Data Persistence
- **SharedPreferences** store:
  - `'banques'`: StringList of bank names
  - `'ops'`: JSON string of encoded operations (use `jsonEncode()/jsonDecode()`)
- Calls `_sauver()` after any state mutation that should persist
- Builds `_toutesLesOps` from JSON in `_charger()` on app init

## Critical Workflows

### Adding a Transaction
1. Tap FAB on `EcranPrincipal`
2. Navigate to `EcranSaisie` with current date and bank context
3. Fill form → creates `Operation` with UUID as `id` (using `DateTime.now().toString()`)
4. Navigation returns `Operation` object to main screen
5. Add to `_toutesLesOps` and call `_sauver()`

### Filtering & Display Logic
The `_doitAfficher()` method controls visibility:
- Must match active bank
- "Ponctuel" operations show on exact date only
- Recurring operations start from their creation date
- For monthly/quarterly/biannual: matches day-of-month, with modulo arithmetic for interval
- Annual: matches both day and month

### Building & Running
```bash
flutter pub get                           # Fetch dependencies
flutter run -d <device>                  # Run on specific device
flutter run -d chrome                    # Run web version
flutter build apk                        # Android release
flutter build ios                        # iOS release
```

## Conventions & Patterns

### Naming
- **French-first**: UI strings, method names, variable names use French (`_toutesLesOps`, `_banqueActive`, `EcranPrincipal`, `_doitAfficher`)
- Use **underscore prefix** for private variables and methods
- Boolean properties: `est` prefix (e.g., `estDepense`, `estPointer`)

### Data Flow
- **Unidirectional lift-up**: Child screens (EcranSaisie) return data via Navigator, parent updates state
- No shared state libraries — keep data flow simple through constructor parameters and returns
- Cache calculations explicitly (`_soldeTotal` getter recalculates from `_toutesLesOps` each build)

### UI Patterns
- **Material Design** with AppBar, IconButton, ListTile, Dialog for confirmations
- **Long-press** for destructive actions (delete)
- **Currency formatting**: `toStringAsFixed(2)` + " €"
- **Color coding**: Red for expenses, Green for income

## Integration Points

### Key Dependencies
- `table_calendar: ^3.2.0` - Calendar widget, expects 'fr_FR' locale
- `intl: ^0.20.2` - Localization (only French date formatting initialized)
- `shared_preferences: ^2.5.4` - Local persistence
- `file_picker: ^10.3.10` - In pubspec but **unused** (no file I/O currently)

### Date Handling
- `initializeDateFormatting('fr_FR')` called in `main()` before runApp
- Use `isSameDay()` from table_calendar for date comparison
- Operations stored as `.toIso8601String()` and `.parse()`d back

## Important Constraints & Gotchas

1. **No Error Handling**: Currency parsing uses `?.toDouble() ?? 0` — invalid amounts silently convert to 0
2. **ID Generation**: Uses `DateTime.now().toString()` which is **not unique** if multiple operations created in same millisecond
3. **No Data Validation**: Description and amount can be empty or negative
4. **Frequency Math Bug Risk**: Modulo arithmetic in `_doitAfficher()` may fail for month-boundaries (Dec→Jan transitions untested)
5. **Performance**: No pagination — all operations loaded into memory at launch
6. **No Backup/Export**: Data only persists in SharedPreferences (device-dependent)

## Testing
- Unit test boilerplate exists: [test/widget_test.dart](../../test/widget_test.dart)
- No meaningful tests currently implemented
- Recommend testing `_doitAfficher()` frequency logic and `_soldeTotal` calculations

## Common Tasks

**Adding a new frequency type:**
1. Add string to dropdown items list in `EcranSaisie`
2. Add condition in `_doitAfficher()` following modulo pattern
3. Test boundary conditions (month-end, year-end transitions)

**Persisting new fields:**
1. Add to `Operation` class
2. Add to `toMap()` and `fromMap()`
3. Migrate existing SharedPreferences data or accept data loss on first launch

**Switching state management:**
1. Extract `_toutesLesOps`, `_mesBanques` into separate ChangeNotifier or Controller
2. Replace setState calls with notifyListeners()
3. Refactor screens to use Consumer widgets (Riverpod) or Provider.watch()
