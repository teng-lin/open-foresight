import 'package:flutter/material.dart';

/// Original Google Sans assets; role sizes and colors follow the supplied
/// main-window Mac references. Host accessibility text scaling stays enabled.
ThemeData foresightTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff07577b),
        surface: Colors.white,
      ).copyWith(
        primary: const Color(0xff006c97),
        primaryContainer: const Color(0xffbfe8ff),
      );
  return ThemeData(
    fontFamily: 'GoogleSans',
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xffeaeef7),
    useMaterial3: true,
    dividerColor: const Color(0xffeceef0),
    dividerTheme: const DividerThemeData(
      color: Color(0xffeceef0),
      thickness: 1,
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        height: 1.3,
      ),
      bodyMedium: TextStyle(
        fontSize: 12,
        letterSpacing: 0,
        height: 1.3,
        color: Color(0xff26272b),
      ),
      bodySmall: TextStyle(
        fontSize: 11,
        letterSpacing: 0,
        height: 1.3,
        color: Color(0xff74777d),
      ),
      titleMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        height: 1.3,
      ),
      headlineSmall: TextStyle(fontSize: 28, fontWeight: FontWeight.w400),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        height: 1.2,
      ),
      labelLarge: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        height: 1.2,
      ),
      labelMedium: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        height: 1.2,
      ),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
      minVerticalPadding: 12,
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: Color(0xfff8fafd),
      side: BorderSide.none,
      labelStyle: TextStyle(
        fontFamily: 'GoogleSans',
        fontSize: 11,
        color: Color(0xff26272b),
        letterSpacing: 0,
      ),
      padding: EdgeInsets.symmetric(horizontal: 6),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        side: const WidgetStatePropertyAll(BorderSide.none),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? const Color(0xffbfe8ff)
              : const Color(0xffdee3e9),
        ),
      ),
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: Color(0xffeaeef7),
      indicatorColor: Color(0xffbfe8ff),
      selectedIconTheme: IconThemeData(color: Color(0xff07577b)),
      selectedLabelTextStyle: TextStyle(
        color: Color(0xff07577b),
        fontWeight: FontWeight.w700,
      ),
      unselectedLabelTextStyle: TextStyle(color: Color(0xff60646b)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xffdfe1e7)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xffdfe1e7)),
      ),
    ),
  );
}

class ForesightBrand extends StatelessWidget {
  final bool inverse;
  const ForesightBrand({super.key, this.inverse = false});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (inverse)
        SizedBox(
          width: 28,
          height: 28,
          child: Stack(
            children: [
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                right: 4,
                top: 10,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: Color(0xff35373d),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        )
      else
        Image.asset('assets/images/foresight-logo.png', width: 34, height: 34),
      const SizedBox(width: 10),
      Text(
        'foresight',
        style: TextStyle(
          fontSize: 23,
          fontWeight: FontWeight.w700,
          color: inverse ? Colors.white : const Color(0xff202124),
        ),
      ),
    ],
  );
}

class CopilotPanel extends StatelessWidget {
  final Widget child;
  const CopilotPanel({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(24),
      gradient: const LinearGradient(
        colors: [Color(0xff303136), Color(0xff53493f), Color(0xff343d56)],
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x22000000),
          blurRadius: 24,
          offset: Offset(0, 8),
        ),
      ],
    ),
    padding: const EdgeInsets.all(24),
    child: Theme(
      data: Theme.of(context).copyWith(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          surface: Color(0xff3b3d44),
        ),
        textTheme: Theme.of(
          context,
        ).textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
        cardTheme: CardThemeData(
          color: const Color(0xff42434a),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xff55545b),
          hintStyle: const TextStyle(color: Color(0xffdedee3)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          fontFamily: 'GoogleSans',
          color: Colors.white,
          fontSize: 15,
        ),
        child: child,
      ),
    ),
  );
}
