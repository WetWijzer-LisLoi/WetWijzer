// PWA glue: register the service worker and drive the "install to home screen"
// banner. On Android/desktop Chrome we capture beforeinstallprompt and show a
// one-tap Install button. On iOS Safari (no such event) we show the manual
// "Share -> Add to Home Screen" hint. Hidden once installed or dismissed.
//
// The banner element is marked data-turbo-permanent in the layout so it survives
// Turbo navigations; we still re-check on turbo:load and guard against double
// wiring, so this is safe whether or not Turbo preserves the node.

// v2: the previous key was also written on 'appinstalled', so uninstalling the
// app left a 30-day suppression behind and the install prompt never came back
// (reported 2026-08-19). The key is versioned so those stale timestamps are
// ignored once instead of stranding users for a month; the legacy value is
// cleaned up on read.
const DISMISS_KEY = 'pwa-install-dismissed-at-v2';
const LEGACY_DISMISS_KEY = 'pwa-install-dismissed-at';
const DISMISS_DAYS = 30;

let deferredPrompt = null;

function isStandalone() {
  return (
    window.matchMedia('(display-mode: standalone)').matches ||
    window.navigator.standalone === true
  );
}

function recentlyDismissed() {
  try {
    try { localStorage.removeItem(LEGACY_DISMISS_KEY); } catch (_) { /* ignore */ }
    const raw = localStorage.getItem(DISMISS_KEY);
    if (!raw) return false;

    const ts = Number(raw);
    const age = Date.now() - ts;
    const active = Number.isFinite(ts) && ts > 0 && age >= 0 && age < DISMISS_DAYS * 864e5;
    if (!active) localStorage.removeItem(DISMISS_KEY);
    return active;
  } catch (_) {
    // Storage may be unavailable in hardened/private browser modes. The PWA
    // prompt is optional and must never break the rest of the application.
    return false;
  }
}

function rememberDismissal() {
  try {
    localStorage.setItem(DISMISS_KEY, String(Date.now()));
  } catch (_) {
    // An unavailable preference store merely means the banner may reappear.
  }
}

function suppressed() {
  // Always evaluate the dismissal timestamp so an installed/standalone visit
  // also clears it after the documented retention period.
  const dismissed = recentlyDismissed();
  return isStandalone() || dismissed;
}

function isIosSafari() {
  const ua = window.navigator.userAgent;
  const iOS = /iPad|iPhone|iPod/.test(ua) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1); // iPadOS
  const webkit = /WebKit/.test(ua);
  const notOtherBrowser = !/CriOS|FxiOS|EdgiOS|OPiOS/.test(ua);
  return iOS && webkit && notOtherBrowser;
}

function els() {
  return {
    banner: document.getElementById('pwa-install-banner'),
    installBtn: document.getElementById('pwa-install-button'),
    iosHint: document.getElementById('pwa-ios-hint'),
    dismissBtn: document.getElementById('pwa-install-dismiss')
  };
}

// The banner is a full-width fixed bar at the bottom (z-1000). The floating chatbot
// button (#chatbot-widget-container, bottom-right) sits inside that area, so when the
// banner shows it would cover the chat icon. Lift the FAB above the banner while it's
// visible, and restore it when hidden.
function liftChatbotFab(banner) {
  // Lift the FAB button and its toast - NOT #chatbot-widget-container.
  // A transformed element becomes the containing block for its
  // position:fixed descendants, and the chat panel inside that container is
  // fixed + inset:0 on mobile. Transforming the container therefore resolved
  // the panel against the container's zero-width box in the screen corner and
  // threw the whole panel one viewport-width off to the right, which made the
  // page pan sideways on phones (verified in-browser 2026-08-19: panel
  // left=13 -> left=536 the moment the transform was applied). The FAB and the
  // toast have no fixed descendants, so lifting them is safe.
  const targets = [
    document.getElementById('chatbot-fab'),
    document.getElementById('chatbot-context-toast')
  ].filter(Boolean);
  if (!targets.length) return;
  if (banner) {
    const h = Math.round(banner.getBoundingClientRect().height);
    if (h > 0) {
      // Use transform, not `bottom`: the widget is draggable and its position is
      // over-constrained (top+bottom) so `bottom` has no effect, whereas transform
      // reliably shifts it visually above the banner.
      targets.forEach(function (el) {
        el.style.transition = 'transform .2s ease';
        el.style.transform = 'translateY(-' + (h + 12) + 'px)';
      });
    }
  } else {
    targets.forEach(function (el) {
      el.style.transform = '';
      el.style.transition = '';
    });
  }
}

function showAndroid() {
  if (suppressed()) return;
  const { banner, installBtn, iosHint } = els();
  if (!banner) return;
  if (installBtn) installBtn.style.display = 'inline-block';
  if (iosHint) iosHint.style.display = 'none';
  banner.style.display = 'flex';
  liftChatbotFab(banner);
}

function showIos() {
  if (suppressed()) return;
  const { banner, installBtn, iosHint } = els();
  if (!banner) return;
  if (installBtn) installBtn.style.display = 'none';
  if (iosHint) iosHint.style.display = 'block';
  banner.style.display = 'flex';
  liftChatbotFab(banner);
}

function hide() {
  const { banner } = els();
  if (banner) banner.style.display = 'none';
  liftChatbotFab(null);
}

// Bound once at module load so we never miss an early event.
window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault();
  deferredPrompt = e;
  showAndroid();
});

window.addEventListener('appinstalled', () => {
  // Deliberately does NOT persist a dismissal. While the app is installed the
  // browser does not fire beforeinstallprompt and isStandalone() hides the
  // banner anyway, so recording one only had an effect AFTER an uninstall -
  // where it wrongly suppressed the prompt for the rest of the 30 days.
  deferredPrompt = null;
  hide();
});

function wireBanner() {
  const { banner, installBtn, dismissBtn } = els();
  if (!banner) return;

  if (!banner.dataset.pwaWired) {
    banner.dataset.pwaWired = '1';

    installBtn?.addEventListener('click', async () => {
      if (!deferredPrompt) return;
      deferredPrompt.prompt();
      try { await deferredPrompt.userChoice; } catch (_) { /* ignore */ }
      deferredPrompt = null;
      hide();
    });

    dismissBtn?.addEventListener('click', () => {
      rememberDismissal();
      hide();
    });
  }

  // Decide what (if anything) to show now.
  if (deferredPrompt) showAndroid();
  else if (isIosSafari()) showIos();
}

function registerServiceWorker() {
  if (!('serviceWorker' in navigator)) return;
  window.addEventListener('load', () => {
    // updateViaCache: 'none' forces the browser to revalidate sw.js on every
    // registration, so a new SW ships even though it is served as a static file.
    navigator.serviceWorker.register('/sw.js', { updateViaCache: 'none' }).catch((e) => {
      console.warn('[pwa] service worker registration failed', e);
    });
  });
}

registerServiceWorker();

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', wireBanner);
} else {
  wireBanner();
}
document.addEventListener('turbo:load', wireBanner);
