import 'package:flutter/material.dart';

/// Whether the OS asks for reduced motion ("Bewegung reduzieren",
/// docs/KONZEPT.md "Bewegung"). Every transition below is skipped then.
bool reduceMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

const _duration = Duration(milliseconds: 320);
const _curve = Curves.easeInOutCubic;

/// Route for the screens that live "under" the player: the library (and
/// through it the settings). Decision E49: the player is the root route
/// and stays mounted (its sleep timer lives there, E29), so the motion is
/// staged from both sides -- the [PlayerRoute] below slides down on this
/// route's animation while this route shows only the strip the player has
/// already left. Reversed (mini player tap, back), the player slides up
/// over the library. With [instant] (app start) there is no transition.
class UnderPlayerRoute<T> extends PageRoute<T> {
  final WidgetBuilder builder;
  final bool instant;

  UnderPlayerRoute({required this.builder, this.instant = false, super.settings});

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  bool get opaque => true;

  @override
  Duration get transitionDuration => instant ? Duration.zero : _duration;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduceMotion(context)) return child;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) => ClipRect(
        clipper: _TopStripClipper(_curve.transform(animation.value)),
        child: child,
      ),
      child: child,
    );
  }
}

/// Clips to the top [fraction] of the box: the strip the sliding player
/// has uncovered.
class _TopStripClipper extends CustomClipper<Rect> {
  final double fraction;

  const _TopStripClipper(this.fraction);

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width, size.height * fraction);

  @override
  bool shouldReclip(_TopStripClipper oldClipper) => oldClipper.fraction != fraction;
}

/// The player's route (decision E49). Pushed over the library it slides up
/// from the bottom; while an [UnderPlayerRoute] is pushed over it, it
/// slides down out of view (and back up when that route pops). Other
/// routes on top (the Faden screen) get the platform's page transition.
class PlayerRoute extends MaterialPageRoute<void> {
  final bool instant;
  Route<dynamic>? _above;

  PlayerRoute({required super.builder, this.instant = false, super.settings});

  @override
  Duration get transitionDuration => instant ? Duration.zero : _duration;

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) =>
      nextRoute is UnderPlayerRoute || super.canTransitionTo(nextRoute);

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    // Null once the route above is gone; the secondary animation is then
    // dismissed anyway, so the last known one may stay.
    if (nextRoute != null) _above = nextRoute;
    super.didChangeNext(nextRoute);
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    _above = nextRoute;
    super.didPopNext(nextRoute);
  }

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
    if (_above is UnderPlayerRoute) {
      return SlideTransition(
        position: secondaryAnimation
            .drive(Tween(begin: Offset.zero, end: const Offset(0, 1)).chain(CurveTween(curve: _curve))),
        child: entering,
      );
    }
    return super.buildTransitions(context, kAlwaysCompleteAnimation, secondaryAnimation, entering);
  }
}
