import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Shared desktop roles inferred from the original Mac app's visible controls.
/// Roles describe hierarchy; they do not override accessibility text scaling.
abstract final class DesktopVisuals {
  static const pageTitle = TextStyle(fontSize: 28, height: 1.1);
  static const sectionTitle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    height: 1.3,
  );
  static const control = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.3,
  );
  static const field = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.3,
    color: Color(0xff26272b),
  );
  static const dialogTitle = TextStyle(
    fontFamily: 'GoogleSans',
    fontSize: 24,
    fontWeight: FontWeight.w400,
    height: 1.3,
    color: Color(0xff26272b),
  );
  static const dialogBody = TextStyle(
    fontFamily: 'GoogleSans',
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: Color(0xff26272b),
  );
  static const fieldSurface = Color(0xffdee3e9);
  static const dialogSurface = Color(0xffe8eff7);
  static const panelRadius = BorderRadius.all(Radius.circular(16));
  // A 40px action target plus 4px padding gives the reference's ~44px list row.
  static const sourceRowPadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 2,
  );
  static const sourceHeaderPadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 9,
  );
}

/// The filled selectors used in Settings retain Flutter's keyboard, focus,
/// selection and disabled behavior, without the default underline.
class DesktopSettingSelect<T> extends StatelessWidget {
  const DesktopSettingSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.width,
  });
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final double? width;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    constraints: const BoxConstraints(minHeight: 48),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    decoration: BoxDecoration(
      color: DesktopVisuals.fieldSurface,
      borderRadius: BorderRadius.circular(6),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        items: items,
        onChanged: onChanged,
        isExpanded: width != null,
        isDense: true,
        style: DesktopVisuals.field.copyWith(
          fontFamily: 'GoogleSans',
          color: onChanged == null
              ? Theme.of(context).disabledColor
              : DesktopVisuals.field.color,
        ),
        icon: const Icon(Icons.unfold_more, size: 18),
        borderRadius: BorderRadius.circular(8),
        dropdownColor: Colors.white,
      ),
    ),
  );
}

class DesktopImportMenuTile extends StatelessWidget {
  const DesktopImportMenuTile({
    super.key,
    required this.icon,
    required this.label,
  });
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => ListTile(
    minTileHeight: 48,
    minVerticalPadding: 0,
    leading: Icon(icon, size: 24),
    title: Text(label, style: DesktopVisuals.control),
  );
}

/// Keep large, grouped counts readable without spilling outside their card.
class DesktopMetricValue extends StatelessWidget {
  const DesktopMetricValue(this.value, {super.key, this.fontSize = 24});
  final int value;
  final double fontSize;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Text(
      NumberFormat.decimalPattern(
        Localizations.localeOf(context).toLanguageTag(),
      ).format(value),
      style: TextStyle(fontSize: fontSize),
    ),
  );
}
