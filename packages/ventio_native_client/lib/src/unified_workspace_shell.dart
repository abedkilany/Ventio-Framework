import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_database.dart';

/// Local presentation preference only; it is never authorization state.
abstract interface class VentioSidebarPreferences {
  Future<bool> load(String scope);
  Future<void> save(String scope, bool pinned);
}

class _FileSidebarPreferences implements VentioSidebarPreferences {
  const _FileSidebarPreferences();

  Future<File> _file(String scope) async {
    final directory = await ventioApplicationSupportDirectory();
    final digest = sha256.convert(utf8.encode(scope));
    return File(p.join(directory.path, 'sidebar-$digest.txt'));
  }

  @override
  Future<bool> load(String scope) async {
    final file = await _file(scope);
    return await file.exists() &&
        (await file.readAsString()).trim() == 'pinned';
  }

  @override
  Future<void> save(String scope, bool pinned) async {
    final file = await _file(scope);
    await file.parent.create(recursive: true);
    await file.writeAsString(pinned ? 'pinned' : 'auto', flush: true);
  }
}

/// Navigation sections are supplied by the authenticated workspace. Shortcuts
/// call existing guarded operations; neither the shell nor a menu grants access.
class VentioWorkspaceSection {
  const VentioWorkspaceSection({
    required this.id,
    required this.label,
    required this.icon,
    required this.builder,
    this.parentId,
    this.onOpen,
  });

  final String id;
  final String label;
  final IconData icon;
  final WidgetBuilder builder;
  final String? parentId;
  final VoidCallback? onOpen;
}

class VentioWorkspaceShell extends StatefulWidget {
  const VentioWorkspaceShell({
    required this.sections,
    required this.connectionLabel,
    required this.connectionIcon,
    required this.onRefresh,
    this.onSignOut,
    this.navigatorKey,
    this.accountLabel,
    this.authorizationRevision,
    this.sidebarPreferenceScope,
    this.sidebarPreferences = const _FileSidebarPreferences(),
    super.key,
  }) : assert(sections.length > 0);

  final List<VentioWorkspaceSection> sections;
  final String connectionLabel;
  final IconData connectionIcon;
  final VoidCallback onRefresh;
  final VoidCallback? onSignOut;
  final GlobalKey<NavigatorState>? navigatorKey;
  final String? accountLabel;
  final String? authorizationRevision;
  final String? sidebarPreferenceScope;
  final VentioSidebarPreferences sidebarPreferences;

  static void selectSection(BuildContext context, String id) {
    context.findAncestorStateOfType<_VentioWorkspaceShellState>()?._select(id);
  }

  @override
  State<VentioWorkspaceShell> createState() => _VentioWorkspaceShellState();
}

class _VentioWorkspaceShellState extends State<VentioWorkspaceShell> {
  String _selected = 'home';
  static const double _headerHeight = 60;
  static const double _sidebarWidth = 244;
  static const Duration _slideDuration = Duration(milliseconds: 180);
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _navigationFocus = FocusNode(debugLabel: 'Workspace navigation');
  final _menuFocus = FocusNode(debugLabel: 'Open navigation');
  bool _pinned = false;
  bool _sidebarOpen = false;
  bool _hoverReveal = false;
  bool _keepSidebar = false;
  int _preferenceGeneration = 0;
  Timer? _hideTimer;
  Future<void> _preferenceWrites = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _loadSidebarPreference();
  }

  Future<void> _loadSidebarPreference() async {
    final generation = ++_preferenceGeneration;
    final scope = widget.sidebarPreferenceScope;
    if (scope == null) return;
    try {
      final pinned = await widget.sidebarPreferences.load(scope);
      if (!mounted || generation != _preferenceGeneration) return;
      setState(() {
        _pinned = pinned;
        if (pinned) _keepSidebar = true;
      });
    } catch (_) {
      // An unreadable optional preference must not block workspace access.
    }
  }

  void _setPinned(bool value) {
    _hideTimer?.cancel();
    ++_preferenceGeneration;
    setState(() {
      _pinned = value;
      _sidebarOpen = false;
      _hoverReveal = false;
      _keepSidebar = true;
    });
    if (!value && _navigationFocus.hasFocus) {
      _menuFocus.requestFocus();
    }
    final scope = widget.sidebarPreferenceScope;
    if (scope == null) return;
    final store = widget.sidebarPreferences;
    // Serialize rapid pin/unpin actions so the last choice wins on disk.
    _preferenceWrites = _preferenceWrites.then((_) async {
      try {
        await store.save(scope, value);
      } catch (_) {
        if (mounted && widget.sidebarPreferenceScope == scope) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text('Sidebar preference could not be saved.'),
            ),
          );
        }
      }
    });
  }

  void _openSidebar({bool hover = false}) {
    _hideTimer?.cancel();
    if (_sidebarOpen && hover) return;
    setState(() {
      _sidebarOpen = true;
      _hoverReveal = hover;
      _keepSidebar = true;
    });
    if (!hover) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _sidebarOpen) _navigationFocus.requestFocus();
      });
    }
  }

  void _closeSidebar() {
    _hideTimer?.cancel();
    if (!_sidebarOpen) return;
    setState(() {
      _sidebarOpen = false;
      _hoverReveal = false;
    });
    if (_navigationFocus.hasFocus) {
      _menuFocus.requestFocus();
    }
  }

  void _scheduleHoverHide() {
    _hideTimer?.cancel();
    if (!_hoverReveal) return;
    _hideTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted && _hoverReveal) _closeSidebar();
    });
  }

  void _toggleNavigation(bool drawer, bool pinned) {
    if (drawer) {
      final scaffold = _scaffoldKey.currentState;
      if (scaffold?.isDrawerOpen == true) {
        scaffold?.closeDrawer();
      } else {
        scaffold?.openDrawer();
      }
    } else if (pinned) {
      _navigationFocus.requestFocus();
    } else if (_sidebarOpen) {
      _closeSidebar();
    } else {
      _openSidebar();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _navigationFocus.dispose();
    _menuFocus.dispose();
    super.dispose();
  }

  bool _switching = false;
  final _expanded = <String>{'applications', 'workspaces'};
  final _localNavigatorKey = GlobalKey<NavigatorState>();
  GlobalKey<NavigatorState> get _navigatorKey =>
      widget.navigatorKey ?? _localNavigatorKey;

  VentioWorkspaceSection? _section(String id) {
    for (final section in widget.sections) {
      if (section.id == id) return section;
    }
    return null;
  }

  VentioWorkspaceSection get _current =>
      _section(_selected) ?? widget.sections.first;

  Future<void> _select(String id, {bool drawer = false}) async {
    if (_switching) return;
    if (drawer) _scaffoldKey.currentState?.closeDrawer();
    final requested = _section(id);
    if (requested == null) return;
    final destination = requested.onOpen == null
        ? requested.id
        : requested.parentId;
    if (destination == null || _section(destination) == null) {
      return;
    }
    if (destination == _current.id && requested.onOpen == null) {
      _closeSidebar();
      return;
    }
    _switching = true;
    try {
      final navigator = _navigatorKey.currentState;
      if (navigator?.canPop() == true) {
        final leave = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Leave current page?'),
            content: const Text('Unsaved changes on this page may be lost.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Stay'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Leave page'),
              ),
            ],
          ),
        );
        if (leave != true || !mounted) return;
        navigator!.popUntil((route) => route.isFirst);
      }
      // Resolve again after the confirmation: permissions may have changed.
      final currentRequest = _section(id);
      if (!mounted || currentRequest == null || _section(destination) == null) {
        return;
      }
      setState(() {
        _selected = destination;
        if (currentRequest.parentId != null) {
          _expanded.add(currentRequest.parentId!);
        }
        if (widget.sections.any((item) => item.parentId == destination)) {
          _expanded.add(destination);
        }
      });
      _closeSidebar();
      currentRequest.onOpen?.call();
    } finally {
      _switching = false;
    }
  }

  @override
  void didUpdateWidget(covariant VentioWorkspaceShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sidebarPreferenceScope != widget.sidebarPreferenceScope) {
      _hideTimer?.cancel();
      _pinned = false;
      _sidebarOpen = false;
      _hoverReveal = false;
      _keepSidebar = false;
      _loadSidebarPreference();
    }
    final removed = _section(_selected) == null;
    final adminChanged =
        _selected == 'administration' &&
        oldWidget.authorizationRevision != widget.authorizationRevision;
    if (removed) _selected = widget.sections.first.id;
    if (removed || adminChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _navigatorKey.currentState?.popUntil((route) => route.isFirst);
      });
    }
  }

  Widget _navItem(
    BuildContext context,
    VentioWorkspaceSection section, {
    required bool drawer,
  }) {
    final colors = Theme.of(context).colorScheme;
    final selected = _current.id == section.id;
    final hasChildren = widget.sections.any(
      (item) => item.parentId == section.id,
    );
    final item = Material(
      key: ValueKey('workspace-item-${section.id}'),
      color: selected ? colors.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: Row(
        children: [
          Expanded(
            child: ListTile(
              key: ValueKey('workspace-nav-${section.id}'),
              dense: true,
              visualDensity: VisualDensity.compact,
              minLeadingWidth: 20,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              selected: selected,
              selectedColor: colors.onPrimaryContainer,
              leading: Icon(section.icon, size: 20),
              title: Text(
                section.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              onTap: () => _select(section.id, drawer: drawer),
            ),
          ),
          if (hasChildren)
            IconButton(
              key: ValueKey('workspace-group-${section.id}'),
              tooltip: _expanded.contains(section.id)
                  ? 'Collapse ${section.label}'
                  : 'Expand ${section.label}',
              iconSize: 17,
              onPressed: () => setState(() {
                if (!_expanded.remove(section.id)) _expanded.add(section.id);
              }),
              icon: Icon(
                _expanded.contains(section.id)
                    ? Icons.expand_more
                    : Icons.chevron_right,
              ),
            ),
        ],
      ),
    );
    // ListTile supplies its own button semantics. Do not layer another
    // selected/button semantics node around a changing navigation subtree.
    return Padding(
      key: ValueKey('workspace-nav-slot-${section.id}'),
      padding: EdgeInsets.only(
        bottom: 3,
        left: section.parentId != null ? 12 : 0,
      ),
      child: item,
    );
  }

  Widget _navigation(
    BuildContext context, {
    required bool drawer,
    required bool canPin,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            key: const ValueKey('workspace-sidebar-header'),
            height: _headerHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Image.asset(
                    'assets/branding/ventio_symbol.png',
                    width: 30,
                    height: 30,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.view_in_ar_outlined,
                      color: colors.primary,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Ventio',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (canPin)
                    IconButton(
                      key: const ValueKey('workspace-pin-sidebar'),
                      tooltip: _pinned
                          ? 'Unpin sidebar (auto-hide)'
                          : 'Pin sidebar',
                      color: _pinned ? colors.primary : colors.onSurfaceVariant,
                      icon: Icon(
                        _pinned ? Icons.push_pin : Icons.push_pin_outlined,
                        size: 20,
                      ),
                      onPressed: () => _setPinned(!_pinned),
                    ),
                  if (drawer)
                    IconButton(
                      tooltip: 'Close navigation',
                      onPressed: () => _scaffoldKey.currentState?.closeDrawer(),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1, thickness: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
            child: Text(
              'WORKSPACE',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              key: const PageStorageKey('ventio-sidebar'),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                for (final section in widget.sections)
                  if (section.parentId == null ||
                      _expanded.contains(section.parentId))
                    _navItem(context, section, drawer: drawer),
              ],
            ),
          ),
          if (!drawer && !(_pinned && canPin)) ...[
            const Divider(height: 1),
            IconButton(
              key: const ValueKey('workspace-hide-navigation'),
              tooltip: 'Hide navigation',
              onPressed: _closeSidebar,
              icon: const Icon(Icons.keyboard_double_arrow_left),
            ),
          ],
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _header(
    BuildContext context, {
    required bool drawer,
    required bool pinned,
    required bool showStatus,
  }) {
    final colors = Theme.of(context).colorScheme;
    final parent = _current.parentId == null
        ? null
        : _section(_current.parentId!);
    final online = widget.connectionLabel.startsWith('Online');
    final account = widget.accountLabel;
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    return Material(
      color: colors.surface,
      child: SizedBox(
        key: const ValueKey('workspace-page-header'),
        height: _headerHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (!pinned)
                IconButton(
                  key: const ValueKey('workspace-open-navigation'),
                  focusNode: _menuFocus,
                  tooltip: 'Open navigation (Ctrl+B)',
                  onPressed: () => _toggleNavigation(drawer, pinned),
                  icon: const Icon(Icons.menu),
                ),
              Expanded(
                child: Row(
                  children: [
                    if (parent != null && wide) ...[
                      Flexible(
                        child: TextButton(
                          onPressed: () => _select(parent.id),
                          child: Text(
                            parent.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                    Flexible(
                      child: Text(
                        _current.label,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              Tooltip(
                message: widget.connectionLabel,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: online
                        ? colors.tertiaryContainer
                        : colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.connectionIcon,
                        color: online
                            ? colors.onTertiaryContainer
                            : colors.onSurfaceVariant,
                        size: 18,
                      ),
                      if (showStatus) ...[
                        const SizedBox(width: 5),
                        Text(
                          widget.connectionLabel,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Refresh workspace',
                onPressed: widget.onRefresh,
                icon: const Icon(Icons.refresh, size: 21),
              ),
              if (widget.onSignOut != null || _section('account') != null)
                PopupMenuButton<String>(
                  key: const ValueKey('workspace-account-menu'),
                  tooltip: 'Account menu',
                  onSelected: (value) {
                    if (value == 'account') _select('account');
                    if (value == 'sign-out') widget.onSignOut?.call();
                  },
                  itemBuilder: (_) => [
                    if (_section('account') != null)
                      const PopupMenuItem(
                        value: 'account',
                        child: Text('Account and sign-in'),
                      ),
                    if (widget.onSignOut != null)
                      const PopupMenuItem(
                        value: 'sign-out',
                        child: Text('Sign out'),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 15,
                          backgroundColor: colors.primaryContainer,
                          foregroundColor: colors.onPrimaryContainer,
                          child: const Icon(Icons.person_outline, size: 18),
                        ),
                        if (wide && account != null) ...[
                          const SizedBox(width: 7),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 120),
                            child: Text(
                              account,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                          const Icon(Icons.expand_more, size: 17),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final drawer = constraints.maxWidth < 720;
      final canPin = constraints.maxWidth >= 960;
      final pinned = canPin && _pinned;
      final visible = !drawer && (pinned || _sidebarOpen);
      final colors = Theme.of(context).colorScheme;
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
              _toggleNavigation(drawer, pinned),
          if (!drawer && _sidebarOpen && !pinned)
            const SingleActivator(LogicalKeyboardKey.escape): _closeSidebar,
        },
        child: Focus(
          autofocus: true,
          skipTraversal: true,
          child: Scaffold(
            key: _scaffoldKey,
            drawer: drawer
                ? Drawer(
                    child: SafeArea(
                      child: _navigation(context, drawer: true, canPin: false),
                    ),
                  )
                : null,
            body: SafeArea(
              child: Stack(
                children: [
                  Row(
                    children: [
                      AnimatedContainer(
                        duration: _slideDuration,
                        curve: Curves.easeOutCubic,
                        width: pinned ? _sidebarWidth : 0,
                      ),
                      Expanded(
                        key: const ValueKey('ventio-workspace-main'),
                        child: Column(
                          children: [
                            _header(
                              context,
                              drawer: drawer,
                              pinned: pinned,
                              showStatus:
                                  constraints.maxWidth -
                                      (pinned ? _sidebarWidth : 0) >=
                                  740,
                            ),
                            const Divider(height: 1, thickness: 1),
                            Expanded(
                              child: _WorkspaceSectionScope(
                                section: _current,
                                child: Navigator(
                                  key: _navigatorKey,
                                  onGenerateRoute: (settings) =>
                                      MaterialPageRoute<void>(
                                        settings: settings,
                                        builder: (_) => const _WorkspaceRoot(),
                                      ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (!drawer && !pinned && _sidebarOpen && !_hoverReveal)
                    Positioned.fill(
                      child: ModalBarrier(
                        color: Colors.transparent,
                        dismissible: true,
                        semanticsLabel: 'Close navigation',
                        onDismiss: _closeSidebar,
                      ),
                    ),
                  if (!drawer && !visible)
                    Positioned(
                      left: 0,
                      top: _headerHeight + 1,
                      bottom: 0,
                      width: 8,
                      child: MouseRegion(
                        key: const ValueKey('workspace-navigation-edge'),
                        opaque: false,
                        hitTestBehavior: HitTestBehavior.translucent,
                        onEnter: (_) => _openSidebar(hover: true),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  AnimatedPositioned(
                    duration: _slideDuration,
                    curve: Curves.easeOutCubic,
                    left: visible ? 0 : -_sidebarWidth - 16,
                    top: 0,
                    bottom: 0,
                    width: _sidebarWidth,
                    onEnd: () {
                      if (mounted && !visible && _keepSidebar) {
                        setState(() => _keepSidebar = false);
                      }
                    },
                    child: Offstage(
                      offstage: drawer || (!visible && !_keepSidebar),
                      child: IgnorePointer(
                        ignoring: !visible,
                        child: ExcludeSemantics(
                          excluding: !visible,
                          child: ExcludeFocus(
                            excluding: !visible,
                            child: Focus(
                              focusNode: _navigationFocus,
                              child: MouseRegion(
                                onEnter: (_) => _hideTimer?.cancel(),
                                onExit: (_) => _scheduleHoverHide(),
                                child: Material(
                                  elevation: pinned ? 0 : 8,
                                  color: colors.surface,
                                  child: DecoratedBox(
                                    position: DecorationPosition.foreground,
                                    decoration: BoxDecoration(
                                      border: Border(
                                        right: BorderSide(
                                          color: colors.outlineVariant,
                                        ),
                                      ),
                                    ),
                                    child: _navigation(
                                      context,
                                      drawer: false,
                                      canPin: canPin,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _WorkspaceSectionScope extends InheritedWidget {
  const _WorkspaceSectionScope({required this.section, required super.child});
  final VentioWorkspaceSection section;
  @override
  bool updateShouldNotify(_WorkspaceSectionScope oldWidget) =>
      oldWidget.section != section;
}

class _WorkspaceRoot extends StatelessWidget {
  const _WorkspaceRoot();
  @override
  Widget build(BuildContext context) {
    final section = context
        .dependOnInheritedWidgetOfExactType<_WorkspaceSectionScope>()!
        .section;
    return KeyedSubtree(
      key: ValueKey(section.id),
      child: section.builder(context),
    );
  }
}

class VentioWorkspaceAction extends StatelessWidget {
  const VentioWorkspaceAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.description,
    super.key,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        enabled: onPressed != null,
        onTap: onPressed,
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 20, color: colors.onPrimaryContainer),
        ),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        subtitle: description == null ? null : Text(description!),
        trailing: Icon(
          Icons.chevron_right,
          size: 20,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Responsive wrap keeps cards natural-height instead of clipping long labels.
class VentioWorkspaceGrid extends StatelessWidget {
  const VentioWorkspaceGrid({
    required this.children,
    this.minCardWidth = 310,
    super.key,
  });
  final List<Widget> children;
  final double minCardWidth;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 12.0;
      final columns = ((constraints.maxWidth + gap) / (minCardWidth + gap))
          .floor()
          .clamp(1, 3);
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final child in children)
            SizedBox(key: child.key, width: width, child: child),
        ],
      );
    },
  );
}
