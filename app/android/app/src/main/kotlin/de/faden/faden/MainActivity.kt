package de.faden.faden

import io.flutter.embedding.android.FlutterFragmentActivity

// M6 (docs/ARCHITEKTUR.md section 9): FlutterFragmentActivity instead of
// FlutterActivity -- the `health` package's Android side requests Health
// Connect permissions via registerForActivityResult, which requires a
// FragmentActivity (see its README's Android setup section).
class MainActivity : FlutterFragmentActivity()
