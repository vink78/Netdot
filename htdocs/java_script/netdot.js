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
            // data-nd-redirect: go to the created object's detail page
            // (prefix ending in the object type + '/').
            var redirect = form.getAttribute('data-nd-redirect');
            if (redirect && res.data && res.data.id !== undefined) {
              status(true, 'Created');
              setTimeout(function () { location.href = redirect + res.data.id; }, 700);
            } else {
              status(true, 'Saved');
              setTimeout(function () { location.reload(); }, 700);
            }
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

  // Per-record Edit / Cancel toggle (related records on the RR host page): each
  // .nd-rec holds a readonly table (.nd-rec-ro) + a hidden form (.nd-rec-form).
  function initRecToggles() {
    var toggles = document.querySelectorAll('.nd-rec-toggle');
    for (var i = 0; i < toggles.length; i++) {
      toggles[i].addEventListener('click', function () {
        var wrap = this.closest('.nd-rec');
        var form = wrap && wrap.querySelector('form.nd-rec-form');
        var ro   = wrap && wrap.querySelector('.nd-rec-ro');
        if (form) { form.style.display = 'block'; }
        if (ro)   { ro.style.display = 'none'; }
      });
    }
    var cancels = document.querySelectorAll('.nd-rec-cancel');
    for (var j = 0; j < cancels.length; j++) {
      cancels[j].addEventListener('click', function () {
        var wrap = this.closest('.nd-rec');
        var form = wrap && wrap.querySelector('form.nd-rec-form');
        var ro   = wrap && wrap.querySelector('.nd-rec-ro');
        if (form) { form.style.display = 'none'; }
        if (ro)   { ro.style.display = 'block'; }
      });
    }
  }

  // Delete buttons: confirm, then DELETE <data-nd-del>, then reload — or go to
  // data-nd-goto when the deleted object IS the current page (page-level delete).
  // A device delete (data-nd-device) additionally offers the default-off choice
  // to also remove the device's IP addresses (and their DNS A/AAAA records) —
  // that cascades to the name RR once it has no sub_records (see Device::delete).
  function initRecDeletes() {
    var dels = document.querySelectorAll('.nd-rec-delete');
    for (var i = 0; i < dels.length; i++) {
      dels[i].addEventListener('click', function () {
        var btn  = this;
        var url  = btn.getAttribute('data-nd-del');
        var goto = btn.getAttribute('data-nd-goto');
        if (!url) { return; }
        if (btn.getAttribute('data-nd-device')) {
          if (!confirm('Delete this device?\n\nIt will be moved to the available asset pool. If you intend to decommission the hardware, remember to remove the asset as well.')) { return; }
          var delIps = confirm("Also delete this device's IP addresses and their DNS A/AAAA records?") ? 1 : 0;
          url += (url.indexOf('?') === -1 ? '?' : '&') + 'delete_ips=' + delIps;
        } else if (!confirm(goto ? 'Delete this object and all its records?' : 'Delete this record?')) { return; }
        btn.disabled = true;
        api('DELETE', url).then(function (res) {
          if (res.ok) {
            status(true, 'Deleted');
            setTimeout(function () { goto ? (location.href = goto) : location.reload(); }, 700);
          } else {
            var msg = (res.data && res.data.error) ? res.data.error : ('Error ' + res.status);
            status(false, msg, 8000);
            btn.disabled = false;
          }
        });
      });
    }
  }

  // List-page batch delete: checked rows -> ONE DELETE /api/<type>?id=1,2,3
  // (the server checks each id on its own and reports {deleted, skipped}).
  function initBatchDelete() {
    var btns   = document.querySelectorAll('button.nd-batch-delete');
    if (!btns.length) { return; }
    var checks = document.querySelectorAll('.nd-batch-check');
    var count  = document.querySelector('.nd-batch-count');
    function checkedIds() {
      var ids = [];
      for (var i = 0; i < checks.length; i++) {
        if (checks[i].checked) {
          var parts = (checks[i].name || '').split('__');
          var id    = parts[parts.length - 1];
          if (/^\d+$/.test(id)) { ids.push(id); }
        }
      }
      return ids;
    }
    function refresh() {
      var n = checkedIds().length;
      if (count) { count.textContent = n ? (n + ' selected') : ''; }
    }
    for (var i = 0; i < checks.length; i++) { checks[i].addEventListener('change', refresh); }
    for (var j = 0; j < btns.length; j++) {
      btns[j].addEventListener('click', function () {
        var btn  = this;
        var base = btn.getAttribute('data-nd-api');
        if (!base) { return; }
        var ids = checkedIds();
        if (!ids.length) { status(false, 'Select at least one row to delete', 4000); return; }
        if (!confirm('Delete ' + ids.length + ' object(s)? This cannot be undone.')) { return; }
        btn.disabled = true;
        api('DELETE', base + '?id=' + ids.join(',')).then(function (res) {
          if (res.ok) {
            var skipped = (res.data && res.data.skipped) ? Object.keys(res.data.skipped).length : 0;
            status(true, 'Deleted ' + res.data.deleted.length + (skipped ? ' (' + skipped + ' skipped)' : ''), 5000);
            setTimeout(function () { location.reload(); }, 1000);
          } else {
            var msg = (res.data && res.data.error) ? res.data.error : ('Error ' + res.status);
            status(false, msg, 8000);
            btn.disabled = false;
          }
        });
      });
    }
  }

  // "Add a record" section: a type <select> reveals the matching pre-rendered
  // form (submitted via POST by initForms). Cancel resets the select.
  function initAddForm() {
    var sel = document.getElementById('nd-add-type');
    if (!sel) { return; }
    var forms = document.querySelectorAll('form.nd-add-form');
    function show(type) {
      for (var i = 0; i < forms.length; i++) {
        forms[i].style.display = (forms[i].getAttribute('data-nd-type') === type) ? 'block' : 'none';
      }
    }
    sel.addEventListener('change', function () { show(sel.value); });
    var cancels = document.querySelectorAll('.nd-add-cancel');
    for (var j = 0; j < cancels.length; j++) {
      cancels[j].addEventListener('click', function () { sel.value = ''; show(''); });
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
    initRecToggles();
    initRecDeletes();
    initAddForm();
    initFkSearch();
  });

  window.ND = { api: api, status: status, collect: collect };
})();
