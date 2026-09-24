import 'package:flutter/material.dart';

/// Whether the OS asks for reduced motion ("Bewegung reduzieren",
/// docs/KONZEPT.md "Bewegung"). Every transition below is skipped then.
bool reduceMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

const _duration = Duration(milliseconds: 320);
const _curve = Curves.easeInOutCubic;

/// Route of the library, the app's base (decision E60): the root of the
/// stack, never animated. Settings, and the player (a [PlayerRoute]), are
/// pushed on top of it.
class BaseRoute<T> extends PageRouteBuilder<T> {
  BaseRoute({required WidgetBuilder builder, super.settings})
      : super(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (context, _, _) => builder(context),
        );
}

/// The player's route (decisions E49, E60). Pushed over the library (or
/// the settings) it slides up from the bottom; closing it (the down
/// chevron, a swipe down, "Bibliothek" in the details sheet) slides it
/// back down, revealing the screen below. Routes on top of it (the Faden
/// screen) get the platform's page transition. With [instant] (app start)
/// there is no transition; with reduced motion every change is immediate.
class PlayerRoute extends MaterialPageRoute<void> {
  final bool instant;

  /// Player routes currently installed in a navigator, so
  /// [PlayerRoute.activeIn] can bring back the one player instead of
  /// stacking a second.
  static final Set<PlayerRoute> _live = {};

  PlayerRoute({required super.builder, this.instant = false, super.settings});

  /// The player route on [navigator]'s stack, if there is one.
  static PlayerRoute? activeIn(NavigatorState navigator) {
    for (final route in _live) {
      if (route.isActive && route.navigator == navigator) return route;
    }
    return null;
  }

  @override
  void install() {
    super.install();
    _live.add(this);
  }

  @override
  void dispose() {
    _live.remove(this);
    super.dispose();
  }

  /// Read from the platform, not a context: the durations are fixed when
  /// the route is installed.
  static bool get _motionReduced =>
      WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;

  @override
  Duration get transitionDuration => instant || _motionReduced ? Duration.zero : _duration;

  @override
  Duration get reverseTransitionDuration => _motionReduced ? Duration.zero : _duration;

  /// No sideways edge swipe (iOS): the player closes downwards, by its
  /// own swipe or the chevron.
  @override
  bool get popGestureEnabled => false;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduceMotion(context)) return child;
    final entering = SlideTransition(
      position: animation.drive(Tween(begin: const Offset(0, 1), end: Offset.zero).chain(CurveTween(curve: _curve))),
      child: child,
    );
    return super.buildTransitions(context, kAlwaysCompleteAnimation, secondaryAnimation, entering);
  }
}
