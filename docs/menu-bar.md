# Menu bar dropdown

How the menu bar dropdown is built, why it is built that way, and the one known issue left, with the evidence behind it.

## Overview

The status item comes from SwiftUI's `MenuBarExtra` with `.menuBarExtraStyle(.menu)`, so the dropdown is a native `NSMenu` that SwiftUI owns. SwiftUI renders a single row in it, the `Traffic` placeholder; every other row is plain AppKit, built by `MenuBarDropdownItems` and appended by `MenuBarDropdownHooks` (`PrizmX/MacUI/MenuBarMenu.swift`).

```
MenuBarExtra (SwiftUI)
└─ NSMenu (owned by SwiftUI)
   ├─ Traffic          SwiftUI placeholder; its view becomes the live chart
   └─ appended rows    AppKit: TUN Mode, System Proxy, Outbound Mode, Profile,
                       Policies, Open Console…, Inspector…, Settings…, Quit
```

Known issue: while the app is active, opening a Policies submenu can make SwiftUI replace the whole item array. The open submenus close, and a group submenu that was about to open may later show on its own, tied to the app's activation. The planned fix is to own the status item (see [Planned fix](#planned-fix)).

## Lifecycle

1. The user clicks the status item. AppKit starts tracking the dropdown (`NSMenu.didBeginTrackingNotification`). On the first open the menu is still empty.
2. SwiftUI inserts the `Traffic` placeholder (`NSMenu.didAddItemNotification`, index 0). The hooks attach the chart's hosting view to it and append the AppKit rows. Notification observers run synchronously, so the rows are in place before the menu first draws.
3. While the menu is open, a 1 Hz timer in `.common` run loop mode refreshes the rows (checkmarks, the TUN uptime badge, the profile title, latencies in an open group). Each setter writes only when the value differs, because any item change makes an open menu lay out again.
4. The Policies submenu builds its groups the first time it opens in a session. A group builds its members only when it opens, since a profile can list thousands of nodes.
5. When tracking ends, the timer stops and the Policies groups are marked stale. They stay in the menu until the next session rebuilds them, so no item is removed while a submenu might still be showing it.

## Why SwiftUI owns no row but the placeholder

Earlier versions rendered the rows in SwiftUI (`Toggle`, `Picker`, `Menu`) and hung the Policies submenu on a SwiftUI `Button` slot. Every SwiftUI pass over the dropdown:

- swapped the submenus of its `Picker` / `Menu` items, and AppKit closes any open submenu in a menu whose item gets a new submenu;
- reset what it did not set itself: the submenu on the slot item, and the badge on the TUN item. Neither write posts `NSMenu.didChangeItemNotification`, so the hooks could not put them back in time.

A pass also runs when a submenu opens. With the pointer resting on Policies, that looped about every 12 ms: open, pass, close, reopen. The Policies submenu and the TUN badge flickered, and the next level could not be opened. Moving every row to AppKit ended the loop.

## Known issue: MenuBarExtra replaces the whole item array

### Symptom

The main menu stays on screen. The Policies submenu and the group submenu close together (sometimes only the group submenu). A moment later the group's node list shows up alone, with no menu around it. That window then shows while the app is active and hides when it is not, again and again.

### Cause

An update of the SwiftUI app graph makes `MenuBarExtra` push a new environment to its menu, and the menu rebuilds its item array with SwiftUI's items only. The appended AppKit rows are removed with everything else. Call stack at the moment the Policies submenu closes (diagnostic build, 2026-10-26):

```
-[NSMenu setItemArray:] → -[NSMenu removeAllItems]
  → -[NSCocoaMenuImpl _menuItem:wasRemovedFromPreviousIndex:]
  → -[NSCocoaMenuImpl _dismissCoalescingSubmenus:animated:]   closes the open submenus
SwiftUI.PlatformItemList.update(_:in:)
SwiftUI.MenuBehavior.menuHostDidChangeItems
SwiftUI.MainMenuItemHost.requestUpdate(after:)
SwiftUI.MenuBehavior.updateEnvironment()
SwiftUI.MenuBarExtraController.updateConfiguration(_:environment:)
SwiftUI.AppMenuBarExtrasController.update(…sceneList:)
SwiftUI.AppDelegate.appGraphDidChange()
SwiftUI.AppGraph.graphDidChange()
SwiftUI.GraphHost.flushTransactions()                          run loop observer
```

Removing the Policies item while its submenu is open dismisses that submenu chain. A group submenu still in its open delay is left without a parent. It appears later as a standalone popup window, which hides on app deactivation like other menu windows.

The hooks append the rows again right after each rebuild (logs show six rebuilds about 18 ms apart), so the menu itself recovers. Only the submenus that were open are lost.

### When it happens

Every failing session in the logs had `NSApp.isActive == true`; sessions with the app inactive did not rebuild when a submenu opened. The app is active right after launch and whenever one of its windows is in front, which is why the first open after a launch fails most often and later opens usually work. Which environment value changes is not visible in the stack. The trigger is inside SwiftUI and cannot be suppressed from the menu code.

### Diagnosis log

The issue was traced with notice-level `os_log` entries, which persist without a running `log stream` (read with `/usr/bin/log show`; in zsh, a bare `log` is a builtin):

- tracking begin and end, and every `install` of the rows with the menu they came from (`from none` means SwiftUI had already removed them);
- `menuWillOpen` / `menuDidClose` of the Policies and group submenus, with the call stack, the current event, the mouse location, whether the submenu was still attached, and `NSApp.isActive`;
- app activation changes.

`NSMenu.didRemoveItemNotification` is not posted for `removeAllItems`, so the rebuild had to be caught from the submenu close it causes. The diagnostics have been removed.

## Planned fix

Drop `MenuBarExtra` and own the status item: an `NSStatusItem` with an `NSMenu` that only the app writes, the chart attached to one of its items. The status item image is set from AppKit, using the same catalog assets and `MenuBarSpeedImage`, so template icons keep the system's tinting. This touches the scene in `PrizmXApp`, `MenuBarStatusLabel` and the shortcut bridge that lives on it, and every menu bar icon state has to be checked again (idle, System Proxy, TUN, colored and monochrome, with and without the speed readout).

## Other AppKit menu notes

- **Badges in an open menu**: replacing one `NSMenuItemBadge` with another keeps the old capsule size until the next change, so "40 ms" shows as "40". Clearing the badge first sizes the new one for its own text (`setBadgeText`).
- **Colored tags**: `NSMenuItemBadge` takes no color. Latencies are badge-like capsules drawn into an image (its drawing handler runs under the menu's appearance), attached to the title at a right tab stop past the group's widest name, and colored like the Policies pane (`LatencyFormat`). AppKit sizes such a row without the attachment and without the check column's indent, and an attachment past the menu's width is not drawn at all, so the group menu reserves the column with `minimumWidth`.
- **A row that keeps the menu open**: a plain item's action ends tracking. `MenuActionView` is a custom view row that handles `mouseUp` itself; it draws the highlight to match a native row (24 pt tall, 5 pt inset, 8 pt corner radius, `controlAccentColor`).
- **Main actor while tracking**: main-queue blocks and main-actor tasks keep running while a status item menu is open, so test results stream into it. A test that pops a menu up from inside a `DispatchQueue.main.async` block blocks the queue and suggests otherwise.
