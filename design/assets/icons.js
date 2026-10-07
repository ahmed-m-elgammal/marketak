/* ============================================================================
   MARKETAK · ماركتك — ICON SPRITE (single source of truth for design/)
   ----------------------------------------------------------------------------
   Every screen page includes this file and references icons with:
       <i data-icon="home"></i>
   The injector below is a classic script (no fetch), so it works on file://,
   GitHub Pages and the visual verifier alike. Icons are drawn on a 24px grid,
   stroke = 1.8, round caps/joins, and inherit `currentColor` so they respond
   to text tokens. Brand glyphs (google / apple / logo-mark) carry their own
   official colours per platform guidelines.
   ========================================================================== */
(function () {
  var S = 'stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" fill="none"';
  var F = 'fill="currentColor"';
  function svg(inner, vb) {
    return '<svg viewBox="' + (vb || '0 0 24 24') + '" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">' + inner + '</svg>';
  }

  var I = {};

  /* ---- Navigation & tabs ------------------------------------------------ */
  I['home']        = svg('<path ' + S + ' d="M4 10.5 12 4l8 6.5V19a1.5 1.5 0 0 1-1.5 1.5H14v-5.5h-4V20.5H5.5A1.5 1.5 0 0 1 4 19z"/>');
  I['home-fill']   = svg('<path ' + F + ' d="M4 10.5 12 4l8 6.5V19a1.5 1.5 0 0 1-1.5 1.5H14v-5.5h-4V20.5H5.5A1.5 1.5 0 0 1 4 19z"/>');
  I['search']      = svg('<circle ' + S + ' cx="11" cy="11" r="6.5"/><path ' + S + ' d="m16 16 4.5 4.5"/>');
  I['cart']        = svg('<path ' + S + ' d="M4.5 8h15l-1.2 10.2a2 2 0 0 1-2 1.8H7.7a2 2 0 0 1-2-1.8z"/><path ' + S + ' d="M8.5 10.5V7a3.5 3.5 0 0 1 7 0v3.5"/>');
  I['cart-fill']   = svg('<path ' + F + ' d="M4.5 8h15l-1.2 10.2a2 2 0 0 1-2 1.8H7.7a2 2 0 0 1-2-1.8z" opacity=".25"/><path ' + S + ' d="M4.5 8h15l-1.2 10.2a2 2 0 0 1-2 1.8H7.7a2 2 0 0 1-2-1.8z"/><path ' + S + ' d="M8.5 10.5V7a3.5 3.5 0 0 1 7 0v3.5"/>');
  I['receipt']     = svg('<path ' + S + ' d="M6 3.5h12V20l-2.4-1.5L13.2 20 12 19.2 10.8 20 8.4 18.5 6 20z"/><path ' + S + ' d="M9 8.5h6M9 12h6"/>');
  I['user']        = svg('<circle ' + S + ' cx="12" cy="8" r="3.5"/><path ' + S + ' d="M5 20c.8-3.5 3.6-5.5 7-5.5s6.2 2 7 5.5"/>');
  I['user-fill']   = svg('<circle ' + F + ' cx="12" cy="8" r="3.5"/><path ' + F + ' d="M5 20c.8-3.5 3.6-5.5 7-5.5s6.2 2 7 5.5z"/>');

  /* ---- Rider mode -------------------------------------------------------- */
  I['helmet']      = svg('<path ' + S + ' d="M4.5 13a7.5 7.5 0 0 1 15 0v1.5a2 2 0 0 1-2 2H14l1-3.5H6.7A2.2 2.2 0 0 1 4.5 10.8"/><path ' + S + ' d="M4.5 13H12"/><path ' + S + ' d="M6.5 16.5V19a1.5 1.5 0 0 0 1.5 1.5h1"/>');
  I['scooter']     = svg('<circle ' + S + ' cx="5.5" cy="17" r="2.5"/><circle ' + S + ' cx="18.5" cy="17" r="2.5"/><path ' + S + ' d="M8 17h8M14.5 5.5H17l1.9 9M9.5 5.5h5M6.5 12.5 8 5.5h1.5M6.5 12.5a2.2 2.2 0 1 0 .5 4.4"/>');
  I['pin']         = svg('<path ' + S + ' d="M12 21s-6.5-5.2-6.5-10a6.5 6.5 0 0 1 13 0c0 4.8-6.5 10-6.5 10z"/><circle ' + S + ' cx="12" cy="10.5" r="2.3"/>');
  I['pin-fill']    = svg('<path ' + F + ' d="M12 21s-6.5-5.2-6.5-10a6.5 6.5 0 0 1 13 0c0 4.8-6.5 10-6.5 10z"/><circle fill="#fff" cx="12" cy="10.5" r="2.2"/>');
  I['route']       = svg('<circle ' + S + ' cx="6" cy="6" r="2.5"/><circle ' + S + ' cx="18" cy="18" r="2.5"/><path ' + S + ' d="M8.5 6H15a3 3 0 0 1 0 6H9a3 3 0 0 0 0 6h6.5"/>');

  /* ---- Actions & controls ------------------------------------------------ */
  I['plus']        = svg('<path ' + S + ' d="M12 5v14M5 12h14"/>');
  I['minus']       = svg('<path ' + S + ' d="M5 12h14"/>');
  I['close']       = svg('<path ' + S + ' d="m6 6 12 12M18 6 6 18"/>');
  I['check']       = svg('<path ' + S + ' d="m5 12.5 4.5 4.5L19 7.5"/>');
  I['check-circle'] = svg('<circle ' + S + ' cx="12" cy="12" r="8.5"/><path ' + S + ' d="m8.5 12.5 2.5 2.5 4.8-5.3"/>');
  I['alert']       = svg('<circle ' + S + ' cx="12" cy="12" r="8.5"/><path ' + S + ' d="M12 8v5"/><circle fill="currentColor" stroke="none" cx="12" cy="16.2" r="1.1"/>');
  I['info']        = svg('<circle ' + S + ' cx="12" cy="12" r="8.5"/><path ' + S + ' d="M12 11v5"/><circle fill="currentColor" stroke="none" cx="12" cy="7.8" r="1.1"/>');
  I['chevron-left'] = svg('<path ' + S + ' d="M14.5 5.5 8 12l6.5 6.5"/>');
  I['chevron-right'] = svg('<path ' + S + ' d="m9.5 5.5 6.5 6.5-6.5 6.5"/>');
  I['chevron-down'] = svg('<path ' + S + ' d="m6 9.5 6 6 6-6"/>');
  I['arrow-left']  = svg('<path ' + S + ' d="M19 12H5m6-6-6 6 6 6"/>');
  I['arrow-right'] = svg('<path ' + S + ' d="m5 12 14-0M13 6l6 6-6 6"/>');
  I['sliders']     = svg('<path ' + S + ' d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle ' + S + ' cx="16" cy="7" r="2"/><circle ' + S + ' cx="7.5" cy="17" r="2"/>');
  I['edit']        = svg('<path ' + S + ' d="M4.5 19.5 5 15 16.8 3.2a1.8 1.8 0 0 1 2.6 0l1.4 1.4a1.8 1.8 0 0 1 0 2.6L9 19z"/>');
  I['trash']       = svg('<path ' + S + ' d="M5 7h14M10 7V5.5A1.5 1.5 0 0 1 11.5 4h1A1.5 1.5 0 0 1 14 5.5V7m-8 0 .8 11.2A2 2 0 0 0 8.8 20h6.4a2 2 0 0 0 2-1.8L18 7"/><path ' + S + ' d="M10 11v5m4-5v5"/>');
  I['refresh']     = svg('<path ' + S + ' d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4v4h-4"/>');
  I['logout']      = svg('<path ' + S + ' d="M14 4H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h7M10 12h10m0 0-3.5-3.5M20 12l-3.5 3.5"/>');
  I['globe']       = svg('<circle ' + S + ' cx="12" cy="12" r="8.5"/><path ' + S + ' d="M3.5 12h17M12 3.5c2.5 2.3 3.8 5.2 3.8 8.5s-1.3 6.2-3.8 8.5c-2.5-2.3-3.8-5.2-3.8-8.5s1.3-6.2 3.8-8.5z"/>');

  /* ---- Commerce & status -------------------------------------------------- */
  I['star']        = svg('<path ' + S + ' d="m12 4 2.4 4.9 5.4.8-3.9 3.8.9 5.4-4.8-2.5-4.8 2.5.9-5.4L4.2 9.7l5.4-.8z"/>');
  I['star-fill']   = svg('<path ' + F + ' d="m12 3.6 2.5 5 5.6.9-4 4 .9 5.5-5-2.6-5 2.6.9-5.5-4-4 5.6-.9z"/>');
  I['clock']       = svg('<circle ' + S + ' cx="12" cy="12" r="8.5"/><path ' + S + ' d="M12 7.5V12l3 2"/>');
  I['cash']        = svg('<rect ' + S + ' x="3" y="7" width="18" height="10" rx="2"/><circle ' + S + ' cx="12" cy="12" r="2.4"/><path ' + S + ' d="M6.5 9.8v.01M17.5 14.2v.01"/>');
  I['wallet']      = svg('<path ' + S + ' d="M4 7.5A2.5 2.5 0 0 1 6.5 5h9A2.5 2.5 0 0 1 18 7.5V8h1a1.5 1.5 0 0 1 1.5 1.5v8A2.5 2.5 0 0 1 18 20H6.5A2.5 2.5 0 0 1 4 17.5z"/><path ' + S + ' d="M4 7.5V17M15.5 13.5h1.5"/>');
  I['gift']        = svg('<rect ' + S + ' x="4" y="9" width="16" height="4" rx="1"/><path ' + S + ' d="M5.5 13v6A1.5 1.5 0 0 0 7 20.5h10a1.5 1.5 0 0 0 1.5-1.5v-6M12 9v11.5M12 9s-.8-4.5-3.5-4.5a1.9 1.9 0 0 0 0 4.5zM12 9s.8-4.5 3.5-4.5a1.9 1.9 0 0 1 0 4.5z"/>');
  I['voucher']     = svg('<path ' + S + ' d="M4 8a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v2a2 2 0 0 0 0 4v2a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-2a2 2 0 0 0 0-4z"/><path ' + S + ' d="M10 9v.01M10 12v.01M10 15v.01"/>');
  I['store']       = svg('<path ' + S + ' d="M4.5 9.5 6 4.5h12l1.5 5M4.5 9.5a2.3 2.3 0 0 0 4.6 0 2.35 2.35 0 0 0 4.7 0 2.3 2.3 0 0 0 4.6 0M5.5 11.5V19a1 1 0 0 0 1 1h11a1 1 0 0 0 1-1v-7.5"/><path ' + S + ' d="M9.5 20v-5h5v5"/>');
  I['bag']         = svg('<path ' + S + ' d="M6 8h12l1 11a1.5 1.5 0 0 1-1.5 1.6h-11A1.5 1.5 0 0 1 5 19z"/><path ' + S + ' d="M9 10.5V7a3 3 0 0 1 6 0v3.5"/>');
  I['phone']       = svg('<path ' + S + ' d="M7 3.5h10a1.5 1.5 0 0 1 1.5 1.5v14a1.5 1.5 0 0 1-1.5 1.5H7A1.5 1.5 0 0 1 5.5 19V5A1.5 1.5 0 0 1 7 3.5z"/><path ' + S + ' d="M10.5 17.5h3"/>');
  I['camera']      = svg('<path ' + S + ' d="M4.5 8.5h3l1.5-2h6l1.5 2h3a1 1 0 0 1 1 1V19a1 1 0 0 1-1 1h-15a1 1 0 0 1-1-1V9.5a1 1 0 0 1 1-1z"/><circle ' + S + ' cx="12" cy="13.5" r="3"/>');
  I['image']       = svg('<rect ' + S + ' x="4" y="5" width="16" height="14" rx="2"/><circle ' + S + ' cx="9" cy="10" r="1.5"/><path ' + S + ' d="m5 18 5-5 3 3 2.5-2.5L20 17"/>');
  I['bell']        = svg('<path ' + S + ' d="M12 4a6 6 0 0 1 6 6v3.5l1.5 3h-15L6 13.5V10a6 6 0 0 1 6-6z"/><path ' + S + ' d="M10 19.5a2 2 0 0 0 4 0"/>');
  I['shield']      = svg('<path ' + S + ' d="M12 3.5 19 6v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z"/><path ' + S + ' d="m9 11.5 2.2 2.3L15.5 9.5"/>');
  I['headset']     = svg('<path ' + S + ' d="M4.5 13a7.5 7.5 0 0 1 15 0"/><rect ' + S + ' x="3.5" y="12.5" width="4" height="6" rx="1.5"/><rect ' + S + ' x="16.5" y="12.5" width="4" height="6" rx="1.5"/><path ' + S + ' d="M19 18.5a4 4 0 0 1-4 3h-2"/>');
  I['offline']     = svg('<path ' + S + ' d="M5 10.5a11 11 0 0 1 4.5-2.6M12 6.5c2.9 0 5.5 1.1 7.5 3M8.2 13.8a7 7 0 0 1 3.8-1.7M15.8 13.8a7 7 0 0 0-1.3-1"/><circle ' + S + ' cx="12" cy="17" r="1" fill="currentColor" stroke="none"/><path ' + S + ' d="m4 4 16 16"/>');
  I['sparkle']     = svg('<path ' + F + ' d="M12 4.5 13.6 10 19 11.5 13.6 13 12 18.5 10.4 13 5 11.5 10.4 10zM18.5 4l.7 2.3L21.5 7l-2.3.7L18.5 10l-.7-2.3L15.5 7l2.3-.7zM5.5 15l.7 2.3 2.3.7-2.3.7-.7 2.3-.7-2.3L2.5 18l2.3-.7z"/>');
  I['flame']       = svg('<path ' + S + ' d="M12 20.5c-3.6 0-6-2.4-6-5.6 0-2.6 1.7-4.4 3-6.1.5 1 .9 1.6 1.8 2.2C11 8.6 11.3 6 13.5 3.5c.4 2.6 1.6 3.7 3 5.4 1 1.3 1.5 2.9 1.5 4.4 0 4-2.4 7.2-6 7.2z"/>');
  I['leaf']        = svg('<path ' + S + ' d="M19.5 4.5C11 4.5 5.5 9 5.5 16c0 1.7.4 3 .4 3s1.6-.4 3.6-.4c7 0 10-6.5 10-14.1z"/><path ' + S + ' d="M5.9 19.1C9 14 13 11 17 9"/>');

  /* ---- Brand: Google G (official 4-colour, per Google identity guide) ---- */
  I['google'] = svg(
    '<path fill="#FFC107" d="M43.611 20.083H42V20H24v8h11.303c-1.649 4.657-6.08 8-11.303 8-6.627 0-12-5.373-12-12s5.373-12 12-12c3.059 0 5.842 1.154 7.961 3.039l5.657-5.657C34.046 6.053 29.268 4 24 4 12.955 4 4 12.955 4 24s8.955 20 20 20 20-8.955 20-20c0-1.341-.138-2.65-.389-3.917z"/>' +
    '<path fill="#FF3D00" d="M6.306 14.691l6.571 4.819C14.655 15.108 18.961 12 24 12c3.059 0 5.842 1.154 7.961 3.039l5.657-5.657C34.046 6.053 29.268 4 24 4 16.318 4 9.656 8.337 6.306 14.691z"/>' +
    '<path fill="#4CAF50" d="M24 44c5.166 0 9.86-1.977 13.409-5.192l-6.19-5.238A11.91 11.91 0 0 1 24 36c-5.202 0-9.619-3.317-11.283-7.946l-6.522 5.025C9.505 39.556 16.227 44 24 44z"/>' +
    '<path fill="#1976D2" d="M43.611 20.083H42V20H24v8h11.303a12.04 12.04 0 0 1-4.087 5.571l.003-.002 6.19 5.238C36.971 39.205 44 34 44 24c0-1.341-.138-2.65-.389-3.917z"/>',
    '0 0 48 48'
  );

  /* ---- Brand: Apple (per Apple Marketing Resources, monochrome) ---------- */
  I['apple'] = svg('<path ' + F + ' d="M17.05 12.54c-.03-2.89 2.36-4.27 2.47-4.34-1.35-1.97-3.44-2.24-4.18-2.27-1.78-.18-3.47 1.05-4.37 1.05-.9 0-2.29-1.02-3.77-1-1.94.03-3.72 1.13-4.72 2.86-2.01 3.49-.51 8.66 1.45 11.49.96 1.39 2.1 2.94 3.6 2.88 1.45-.06 1.99-.93 3.74-.93s2.24.93 3.77.9c1.56-.03 2.55-1.41 3.5-2.8 1.1-1.61 1.55-3.17 1.58-3.25-.04-.02-3.04-1.17-3.07-4.59zM14.14 4.06c.79-.96 1.33-2.29 1.18-3.62-1.14.05-2.53.76-3.35 1.72-.73.85-1.38 2.21-1.21 3.51 1.28.1 2.58-.65 3.38-1.61z"/>');

  /* ---- Brand: Marketak logo mark ------------------------------------------
     A market bag carrying the Arabic letter م — the bag says "your market",
     the م says "Marketak". A thin handle keeps it a BAG (a thick one reads as
     a padlock). Uses brand tokens via currentColor.                          */
  I['logo-mark'] = svg(
    '<path d="M8.7 9.6V7.5a3.3 3.3 0 0 1 6.6 0v2.1" stroke="currentColor" stroke-width="1.9" fill="none" stroke-linecap="round"/>' +
    '<path fill="currentColor" d="M4.6 9.1h14.8c1.15 0 2.05 1 1.95 2.15l-.62 7.6A2.9 2.9 0 0 1 17.85 21.5H6.15a2.9 2.9 0 0 1-2.88-2.65l-.62-7.6C2.55 10.1 3.45 9.1 4.6 9.1z"/>' +
    '<circle cx="13.1" cy="15.1" r="2.75" fill="none" stroke="#fff" stroke-width="1.7"/>' +
    '<path d="M10.7 17.1c-.15 1.5-1.05 2.25-2.3 2.5" stroke="#fff" stroke-width="1.7" fill="none" stroke-linecap="round"/>'
  );

  /* ---- Payment channels (Egypt): simplified glyph plates ----------------- */
  I['vodafone-cash'] = svg(
    '<circle cx="12" cy="12" r="9.5" fill="#E60000"/>' +
    '<path fill="#fff" d="M13.9 7.2c-2 0-3.6 1.4-4.1 3.4l-1.4 5.7c-.1.3.2.6.5.6h1.6l.8-3.2c.4 1 1.3 1.6 2.5 1.6 2.2 0 3.9-1.9 3.9-4.2 0-2.3-1.6-3.9-3.8-3.9zm-.3 5.9c-1.1 0-1.8-.9-1.6-2 .2-1.1 1.1-2 2.2-2s1.8.9 1.6 2c-.2 1.1-1.1 2-2.2 2z"/>'
  );
  I['instapay'] = svg(
    '<rect x="2.5" y="2.5" width="19" height="19" rx="5.5" fill="#00B2A9"/>' +
    '<path fill="#fff" d="M8 7h5.3c2 0 3.4 1.2 3.4 3 0 1.3-.7 2.2-1.8 2.7L17.2 17h-2.5l-2-3.8H10V17H8zm2.4 1.9v2.5h2.7c.9 0 1.5-.5 1.5-1.3 0-.8-.6-1.2-1.5-1.2z"/>'
  );

  /* ---- Device status bar (combined: signal · wifi · battery) ------------- */
  I['statusbar'] = svg(
    '<g fill="currentColor"><rect x="0" y="7" width="3" height="5" rx="1"/><rect x="4.5" y="5" width="3" height="7" rx="1"/><rect x="9" y="3" width="3" height="9" rx="1"/><rect x="13.5" y="1" width="3" height="11" rx="1" opacity=".35"/></g>' +
    '<path fill="currentColor" d="M26 4.6a8.4 8.4 0 0 0-6 2.5l1.4 1.4a6.4 6.4 0 0 1 9.2 0L32 7.1a8.4 8.4 0 0 0-6-2.5zm0 4.3c-1 0-2 .4-2.7 1.1L26 12.9l2.7-2.9A3.8 3.8 0 0 0 26 8.9z"/>' +
    '<rect x="38" y="2" width="13" height="9" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.2" opacity=".5"/><rect x="39.6" y="3.6" width="8.5" height="5.8" rx="1.2" fill="currentColor"/><path fill="currentColor" opacity=".5" d="M52 5v3l2.2-1.3z"/>',
    '0 0 55 13'
  );

  /* ==========================================================================
     INJECTOR — replaces every <i data-icon="name"></i> with the inline SVG.
     Idempotent: already-injected hosts (containing an <svg>) are skipped.
     ========================================================================== */
  function inject(root) {
    (root || document).querySelectorAll('[data-icon]').forEach(function (el) {
      if (el.firstElementChild) return;
      var name = el.getAttribute('data-icon');
      if (I[name]) el.innerHTML = I[name];
    });
  }
  window.MarketakIcons = I;
  window.MarketakIcons.inject = inject;
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { inject(); });
  } else {
    inject();
  }
})();
