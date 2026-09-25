import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

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

/// Dragged down this share of the screen height, the player closes on
/// release (decision E63).
const double playerCloseDragFraction = 0.25;

/// Released moving down at least this fast (logical px/s), the player
/// closes however short the drag was (E63). The same speed upwards
/// cancels a long drag.
const double playerCloseFlingVelocity = 700;

/// Whether a drag down the player that ends here closes it (E63): past
/// [playerCloseDragFraction] of [height] (unless flung back up), or flung
/// down faster than [playerCloseFlingVelocity]. Pure, shared by the route
/// that follows the finger and the reduced-motion path that does not.
bool playerDragCloses({required double draggedPx, required double velocity, required double height}) {
  if (velocity >= playerCloseFlingVelocity) return true;
  if (velocity <= -playerCloseFlingVelocity) return false;
  return height > 0 && draggedPx >= height * playerCloseDragFraction;
}

/// The player's route (decisions E49, E60, E63). Pushed over the library
/// (or the settings) it slides up from the bottom; closing it (the down
/// chevron, "Bibliothek" in the details sheet) slides it back down,
/// revealing the screen below. A drag down moves the whole route with the
/// finger ([startDismissDrag]): it drives the route's own animation
/// controller, as the iOS back swipe of a [CupertinoPageRoute] does, so a
/// release finishes the slide from where the finger let go and pops once,
/// or springs back. Routes on top of it (the Faden screen) get the
/// platform's page transition. With [instant] (app start) there is no
/// transition; with reduced motion every change is immediate and the
/// route does not follow a drag.
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
    // Removed mid-drag: the navigator must not stay in a user gesture
    // (it would ignore every touch). In a microtask, not while the
    // navigator is still updating its routes.
    final navigator = _gestureNavigator;
    if (navigator != null) {
      _gestureNavigator = null;
      scheduleMicrotask(() {
        if (navigator.mounted) navigator.didStopUserGesture();
      });
    }
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

  /// The navigator this route told about the running drag
  /// ([NavigatorState.didStartUserGesture]); null while no drag, nor the
  /// slide that finishes one, drives the route.
  NavigatorState? _gestureNavigator;

  /// Bumped by every drag start, so the end of an interrupted spring-back
  /// does not end the drag that caught it.
  int _gestureId = 0;

  /// Whether a drag (or the slide that finishes it) drives the route; its
  /// slide is linear then, so it moves exactly with the finger.
  bool get dismissDragActive => _gestureNavigator != null;

  /// Begins a drag down (E63). False when the route cannot follow one now:
  /// not the top route, nothing below it to reveal (the caller then closes
  /// with [closePlayer] on release), or still sliding in or out. A drag
  /// that catches the route while it springs back takes over from there.
  bool startDismissDrag() {
    final controller = this.controller;
    final navigator = this.navigator;
    if (controller == null || navigator == null || !isCurrent || !navigator.canPop()) return false;
    if (_gestureNavigator == null) {
      if (controller.isAnimating || !controller.isCompleted) return false;
      _gestureNavigator = navigator;
      navigator.didStartUserGesture();
    } else {
      controller.stop();
    }
    _gestureId++;
    return true;
  }

  /// The finger moved [deltaPx] down (negative: up) on a screen [height]
  /// high. 1:1: the route moves by exactly that much, and never above its
  /// resting place (the controller stops at 1).
  void updateDismissDrag(double deltaPx, double height) {
    final controller = this.controller;
    if (controller == null || _gestureNavigator == null || height <= 0 || !isCurrent) return;
    controller.value -= deltaPx / height;
  }

  /// The finger let go, moving at [velocity] px/s (positive: down). Closes
  /// ([playerDragCloses]): pops once and finishes the slide from here at
  /// the finger's speed. Otherwise springs back into place.
  void endDismissDrag(double velocity, double height) {
    final controller = this.controller;
    final navigator = _gestureNavigator;
    if (controller == null || navigator == null) return;
    final id = _gestureId;
    final value = controller.value;
    TickerFuture? settling;
    if (isCurrent && playerDragCloses(draggedPx: (1 - value) * height, velocity: velocity, height: height)) {
      navigator.pop();
      if (controller.isAnimating) {
        // As fast as the finger (easeOutCubic starts at about 3x its mean
        // speed), within sensible bounds.
        final speed = math.max(velocity, 0) / math.max(height, 1);
        final ms = speed <= 0 ? _closeMaxMs : (3 * value / speed * 1000).clamp(_closeMinMs, _closeMaxMs);
        settling = controller.animateBack(
          0,
          duration: Duration(milliseconds: ms.round()),
          curve: Curves.easeOutCubic,
        );
      }
    } else if (isCurrent && value < 1) {
      settling = controller.animateWith(SpringSimulation(_spring, value, 1, -velocity / math.max(height, 1)));
    }
    if (settling == null) {
      _endGesture(id);
    } else {
      settling.whenCompleteOrCancel(() => _endGesture(id));
    }
  }

  static const double _closeMinMs = 120;
  static const double _closeMaxMs = 320;
  static final SpringDescription _spring = SpringDescription.withDampingRatio(mass: 1, stiffness: 520, ratio: 1);

  void _endGesture(int id) {
    final navigator = _gestureNavigator;
    if (id != _gestureId || navigator == null) return;
    _gestureNavigator = null;
    if (navigator.mounted) navigator.didStopUserGesture();
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduceMotion(context)) return child;
    final slide = Tween(begin: const Offset(0, 1), end: Offset.zero);
    final entering = SlideTransition(
      // Linear while a finger (or the slide finishing its drag) drives it;
      // both curves agree at 0 and 1, where the switch happens.
      position: dismissDragActive ? animation.drive(slide) : animation.drive(slide.chain(CurveTween(curve: _curve))),
      child: child,
    );
    return super.buildTransitions(context, kAlwaysCompleteAnimation, secondaryAnimation, entering);
  }
}
