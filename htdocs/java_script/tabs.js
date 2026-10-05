// Client-side tabs for object detail pages (.tabbar + .tab-pane).
// Every pane is rendered up front; this only toggles visibility, so switching
// is instant (no server round-trip). Event delegation on <document> keeps it
// working after htmx content swaps. The active tab is mirrored into ?rel= so a
// deep link / pagination reload lands on the same section.
(function () {
  'use strict';

  function activate(rel) {
    var bar = document.querySelector('.tabbar');
    if (!bar) { return; }
    var tabs = bar.querySelectorAll('.tab');
    var panes = document.querySelectorAll('.tab-pane');
    tabs.forEach(function (t) {
      t.classList.toggle('active', t.getAttribute('data-rel') === rel);
    });
    panes.forEach(function (p) {
      p.hidden = p.getAttribute('data-rel') !== rel;
    });
    try {
      var u = new URL(location.href);
      u.searchParams.set('rel', rel);
      history.replaceState(null, '', u.toString());
    } catch (e) { /* ignore (e.g. file://) */ }
  }

  // Only intercept tabs that carry a data-rel (client-side .tab-pane groups,
  // e.g. the generic detail ?rel= views). Server-rendered tab bars that use
  // plain links (Device / Ipblock ?view= tabs) have NO data-rel and must be
  // left to navigate normally -- so the selector is scoped to [data-rel].
  document.addEventListener('click', function (e) {
    var t = e.target && e.target.closest
          ? e.target.closest('.tabbar .tab[data-rel]') : null;
    if (!t) { return; }
    e.preventDefault();
    activate(t.getAttribute('data-rel'));
  });
})();
