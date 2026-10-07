// netdot.js — shared client for the read-write detail pages.
// Edit forms (form[data-nd-api]) submit to the JSON API via fetch (single write
// path), then show a transient status box and reload on success.
(function () {
  'use strict';

  // fetch <method> <url> (same-origin, JSON body) -> {ok, status, data}.
  function api(method, url, body) {
    var opts = {
      method: method,
      headers: { 'Accept': 'application/json' },
      credentials: 'same-origin'
    };
    if (body !== undefined) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
    return fetch(url, opts).then(function (r) {
      return r.text().then(function (txt) {
        var data;
        try { data = txt ? JSON.parse(txt) : {}; } catch (e) { data = { error: txt || ('HTTP ' + r.status) }; }
        return { ok: r.ok, status: r.status, data: data };
      });
    }).catch(function (e) {
      return { ok: false, status: 0, data: { error: String(e) } };
    });
  }

  // Transient status box, fixed at the bottom of the viewport.
  var box = null, timer = null;
  function status(ok, msg, ms) {
    if (!box) {
      box = document.createElement('div');
      box.className = 'nd-status';
      document.body.appendChild(box);
    }
    clearTimeout(timer);
    box.textContent = msg;
    box.className = 'nd-status ' + (ok ? 'ok' : 'err') + ' show';
    timer = setTimeout(function () {
      box.className = 'nd-status ' + (ok ? 'ok' : 'err');
    }, ms || 4000);
  }

  // Collect a form's named inputs/selects/textarea into a JSON body.
  // checkboxes -> true/false, selects -> id (string) or null, others -> string.
  function collect(form) {
    var body = {};
    var els = form.querySelectorAll('input[name], select[name], textarea[name]');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (el.type === 'checkbox') {
        body[el.name] = el.checked;
      } else if (el.tagName === 'SELECT') {
        body[el.name] = el.value === '' ? null : el.value;
      } else {
        body[el.name] = el.value;
      }
    }
    return body;
  }

  function initForms() {
    var forms = document.querySelectorAll('form[data-nd-api]');
    for (var i = 0; i < forms.length; i++) {
      forms[i].addEventListener('submit', function (e) {
        e.preventDefault();
        var form   = e.target;
        var method = form.getAttribute('data-nd-method') || 'POST';
        var url    = form.getAttribute('data-nd-api');
        var body   = collect(form);
        var btns   = form.querySelectorAll('button[type=submit]');
        for (var b = 0; b < btns.length; b++) { btns[b].disabled = true; }
        api(method, url, body).then(function (res) {
          if (res.ok) {
            status(true, 'Saved');
            setTimeout(function () { location.reload(); }, 700);
          } else {
            var msg = (res.data && res.data.error) ? res.data.error : ('Error ' + res.status);
            status(false, msg, 8000);
            for (var b = 0; b < btns.length; b++) { btns[b].disabled = false; }
          }
        });
      });
    }
  }

  // FK picker: search box (large tables) -> API ?kw= -> fill the <select>.
  function escapeHtml(s) {
    var d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
  }

  function fkSearch(e) {
    var t    = e.target || e.srcElement;
    var wrap = t.closest('.nd-fk-search');
    if (!wrap) { return; }
    var kw   = wrap.querySelector('.nd-fk-kw');
    var sel  = wrap.querySelector('.nd-fk-select');
    var form = wrap.closest('form');
    var base = form ? form.getAttribute('data-nd-api-base') : '/api';
    var q    = (kw.value || '').trim();
    var url  = base + '/' + kw.getAttribute('data-nd-target') + '?kw=' + encodeURIComponent(q) +
               '&limit=' + (kw.getAttribute('data-nd-max') || 100);
    var curId = sel.value;
    api('GET', url).then(function (res) {
      var results = (res.ok && res.data && res.data.results) ? res.data.results : [];
      var html = '<option value="">-- Search --</option>';
      var found = false;
      for (var j = 0; j < results.length; j++) {
        html += '<option value="' + results[j].id + '">' + escapeHtml(results[j].label) + '</option>';
        if (String(results[j].id) === String(curId)) { found = true; }
      }
      if (curId && !found) { html += '<option value="' + curId + '" selected>current (' + curId + ')</option>'; }
      html += '<option value="">[null]</option>';
      sel.innerHTML = html;
      if (curId) { sel.value = curId; }
    });
  }

  function initFkSearch() {
    var btns = document.querySelectorAll('.nd-fk-go');
    for (var i = 0; i < btns.length; i++) {
      btns[i].addEventListener('click', fkSearch);
      var wrap = btns[i].closest('.nd-fk-search');
      var kw   = wrap && wrap.querySelector('.nd-fk-kw');
      if (kw) {
        kw.addEventListener('keydown', function (e) {
          if (e.key === 'Enter') { e.preventDefault(); fkSearch(e); }
        });
      }
    }
  }

  // Edit / Cancel toggle for the generic detail page.
  function initToggle() {
    var toggle   = document.getElementById('nd-edit-toggle');
    var form     = document.getElementById('nd-edit');
    var readonly = document.getElementById('nd-readonly');
    var cancel   = document.getElementById('nd-edit-cancel');
    if (!toggle) { return; }
    toggle.addEventListener('click', function () {
      if (form)     { form.style.display = 'block'; }
      if (readonly) { readonly.style.display = 'none'; }
    });
    if (cancel) {
      cancel.addEventListener('click', function () {
        if (form)     { form.style.display = 'none'; }
        if (readonly) { readonly.style.display = 'block'; }
      });
    }
  }

  document.addEventListener('DOMContentLoaded', function () {
    initForms();
    initToggle();
    initFkSearch();
  });

  window.ND = { api: api, status: status, collect: collect };
})();
