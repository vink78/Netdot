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

  // Human-readable error from an api() result: the server's message, else the status.
  function errMsg(res) {
    return (res.data && res.data.error) ? res.data.error : ('Error ' + res.status);
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

  // Full-screen "busy" overlay with a spinner (a <div>, not a native dialog) shown
  // while a slow server-side write runs (e.g. a recursive Ipblock delete). Blocks
  // interaction until hidden.
  function spinner(show, msg) {
    var el = document.getElementById('nd-busy');
    if (show) {
      if (!el) {
        el = document.createElement('div');
        el.id = 'nd-busy';
        el.className = 'nd-busy';
        el.innerHTML = '<div class="nd-busy-card"><div class="nd-busy-spin"></div>' +
                       '<div class="nd-busy-msg"></div></div>';
        document.body.appendChild(el);
      }
      el.querySelector('.nd-busy-msg').textContent = msg || 'Please wait…';
      el.style.display = 'flex';
      document.body.style.overflow = 'hidden';
    } else if (el) {
      el.style.display = 'none';
      document.body.style.overflow = '';
    }
  }

  // Collect a form's named inputs/selects/textarea into a JSON body.
  // checkboxes -> true/false, selects -> id or null, others -> string.
  // Fields marked data-nd-int that hold a purely-numeric value are sent as an
  // integer (FK ids); non-numeric values (types, addresses) are left as strings.
  function collect(form) {
    var body = {};
    var els = form.querySelectorAll('input[name], select[name], textarea[name]');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (el.type === 'checkbox') {
        body[el.name] = el.checked;
      } else if (el.hasAttribute('data-nd-int') && /^\d+$/.test(el.value)) {
        body[el.name] = parseInt(el.value, 10);
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
      // The DHCP "enable" form nests option_routers into `attributes` — handled by
      // initDhcpEnable (the flat collect() can't build a nested object).
      // The rights form builds a custom payload (subject split + rights array) —
      // handled by initRights.
      if (forms[i].classList.contains('nd-dhcp-enable') || forms[i].classList.contains('nd-rights-add')) { continue; }
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
            var msg = errMsg(res);
            status(false, msg, 8000);
            for (var b = 0; b < btns.length; b++) { btns[b].disabled = false; }
          }
        });
      });
    }
  }

  // DHCP "enable" form: create a type=subnet scope under a global scope. The flat
  // `option_routers` field is moved into the nested `attributes` object before
  // POSTing (the model stores it as a dhcpattr on the new scope).
  function initDhcpEnable() {
    var form = document.querySelector('form.nd-dhcp-enable');
    if (!form) { return; }
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var body = collect(form);
      if (body.option_routers) { body.attributes = { 'option routers': body.option_routers }; }
      delete body.option_routers;
      var btns = form.querySelectorAll('button[type=submit]');
      for (var b = 0; b < btns.length; b++) { btns[b].disabled = true; }
      api('POST', form.getAttribute('data-nd-api'), body).then(function (res) {
        if (res.ok) {
          status(true, 'DHCP enabled');
          setTimeout(function () { location.reload(); }, 700);
        } else {
          status(false, errMsg(res), 8000);
          for (var b = 0; b < btns.length; b++) { btns[b].disabled = false; }
        }
      });
    });
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

  // Modal confirm dialog (a <div>, not a native confirm()). Native confirm()
  // triggers the browser's anti-dialog "don't ask again" permission prompt; a
  // custom div avoids that. Carries an optional checkbox so the choice is made in
  // ONE dialog (no second popup). Resolves {ok, check}: ok=false on Cancel/ESC.
  // Enter does NOT confirm (these are destructive); only the OK button does.
  function ndConfirm(opts) {
    opts = opts || {};
    return new Promise(function (resolve) {
      var ov = document.createElement('div');
      ov.className = 'nd-modal-ov';
      var card = document.createElement('div');
      card.className = 'nd-modal';
      var msg = document.createElement('div');
      msg.className = 'nd-modal-msg';
      msg.textContent = opts.message || '';
      card.appendChild(msg);
      var cb = null;
      if (opts.checkbox) {
        var lbl = document.createElement('label');
        lbl.className = 'nd-modal-check';
        cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = !!opts.checkbox.defaultOn;
        lbl.appendChild(cb);
        lbl.appendChild(document.createTextNode(' ' + opts.checkbox.label));
        card.appendChild(lbl);
      }
      var row = document.createElement('div');
      row.className = 'nd-modal-row';
      var okBtn = document.createElement('button');
      okBtn.type = 'button';
      okBtn.className = 'btn nd-modal-ok';
      okBtn.textContent = opts.okLabel || 'OK';
      var cancelBtn = document.createElement('button');
      cancelBtn.type = 'button';
      cancelBtn.className = 'btn';
      cancelBtn.textContent = opts.cancelLabel || 'Cancel';
      row.appendChild(okBtn);
      row.appendChild(cancelBtn);
      card.appendChild(row);
      ov.appendChild(card);
      document.body.appendChild(ov);
      okBtn.focus();
      function done(ok) {
        document.removeEventListener('keydown', onKey, true);
        if (ov.parentNode) { ov.parentNode.removeChild(ov); }
        resolve({ ok: ok, check: cb ? cb.checked : false });
      }
      function onKey(e) { if (e.key === 'Escape') { done(false); } }
      document.addEventListener('keydown', onKey, true);
      okBtn.addEventListener('click', function () { done(true); });
      cancelBtn.addEventListener('click', function () { done(false); });
      ov.addEventListener('click', function (e) { if (e.target === ov) { done(false); } });
    });
  }

  // Delete buttons: confirm (modal), then DELETE <data-nd-del>, then reload — or
  // go to data-nd-goto when the deleted object IS the current page (page-level
  // delete). An Ipblock delete (data-nd-ipblock) offers the default-off choice to
  // also delete its children (recursive); when off the children are re-attached to
  // the block's parent. A device delete (data-nd-device) offers the default-off
  // choice to also remove its IP addresses / DNS A/AAAA records (see Device::delete).
  function initRecDeletes() {
    var dels = document.querySelectorAll('.nd-rec-delete');
    for (var i = 0; i < dels.length; i++) {
      dels[i].addEventListener('click', function () {
        var btn  = this;
        var url  = btn.getAttribute('data-nd-del');
        var goto = btn.getAttribute('data-nd-goto');
        if (!url) { return; }
        var opt = { message: (goto ? 'Delete this object and all its records?' : 'Delete this record?') };
        if (btn.getAttribute('data-nd-ipblock')) {
          opt.message = 'Delete this IP block?';
          var nch = parseInt(btn.getAttribute('data-nd-children') || '0', 10);
          if (nch > 0) {
            // Default off (Mason): unchecked -> children re-attached to the
            // block's parent (see Ipblock::delete / _tree_delete).
            opt.checkbox = { label: 'Also delete the ' + nch + ' child block(s). If unchecked, they will be re-attached to this block\'s parent.', defaultOn: false };
          }
        } else if (btn.getAttribute('data-nd-device')) {
          opt.message = 'Delete this device?\n\nIt will be moved to the available asset pool. If you intend to decommission the hardware, remember to remove the asset as well.';
          opt.checkbox = { label: 'Also delete this device\'s IP addresses and their DNS A/AAAA records.', defaultOn: false };
        }
        ndConfirm(opt).then(function (r) {
          if (!r.ok) { return; }
          var sep = (url.indexOf('?') === -1 ? '?' : '&');
          if (btn.getAttribute('data-nd-ipblock') && r.check) { url += sep + 'recursive=1'; }
          else if (btn.getAttribute('data-nd-device') && r.check) { url += sep + 'delete_ips=1'; }
          btn.disabled = true;
          spinner(true, 'Deleting…');
          api('DELETE', url).then(function (res) {
            spinner(false);
            if (res.ok) {
              status(true, 'Deleted');
              setTimeout(function () { goto ? (location.href = goto) : location.reload(); }, 700);
            } else {
              var msg = errMsg(res);
              status(false, msg, 8000);
              btn.disabled = false;
            }
          });
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
    var all    = document.querySelector('.nd-batch-select-all');
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
      if (all) {
        all.checked = (n > 0 && n === checks.length);
        all.indeterminate = (n > 0 && n < checks.length);
      }
    }
    if (all) {
      all.addEventListener('change', function () {
        for (var k = 0; k < checks.length; k++) { checks[k].checked = all.checked; }
        refresh();
      });
    }
    for (var i = 0; i < checks.length; i++) { checks[i].addEventListener('change', refresh); }
    refresh();
    for (var j = 0; j < btns.length; j++) {
      btns[j].addEventListener('click', function () {
        var btn  = this;
        var base = btn.getAttribute('data-nd-api');
        if (!base) { return; }
        var ids = checkedIds();
        if (!ids.length) { status(false, 'Select at least one row to delete', 4000); return; }
        ndConfirm({ message: 'Delete ' + ids.length + ' object(s)? This cannot be undone.' }).then(function (r) {
          if (!r.ok) { return; }
          btn.disabled = true;
          spinner(true, 'Deleting ' + ids.length + ' object(s)…');
          api('DELETE', base + '?id=' + ids.join(',')).then(function (res) {
            spinner(false);
            if (res.ok) {
              var skipped = (res.data && res.data.skipped) ? Object.keys(res.data.skipped).length : 0;
              status(true, 'Deleted ' + res.data.deleted.length + (skipped ? ' (' + skipped + ' skipped)' : ''), 5000);
              setTimeout(function () { location.reload(); }, 1000);
            } else {
              var msg = errMsg(res);
              status(false, msg, 8000);
              btn.disabled = false;
            }
          });
        });
      });
    }
  }

  // Bulk edit (port of the legacy edit-multiple.html). On a list / search page
  // with row checkboxes, "Bulk edit" opens a field-picker popup (choose which
  // editable fields), then an editable table: one row per selected object, the
  // chosen fields pre-filled with the current value, plus a per-field "apply to
  // all" row. Save posts ONE request to POST /api/<table>/batch (window.
  // ND_BULK_DATA, stashed by the controller); the server applies per-id and
  // reports a per-id outcome, so there is one consistent result to display.
  function initBulkEdit() {
    var data = window.ND_BULK_DATA || null;
    if (!data || !data.fields || !data.fields.length) { return; }
    var btns   = document.querySelectorAll('button.nd-bulk-edit');
    if (!btns.length) { return; }
    var checks = document.querySelectorAll('.nd-batch-check');
    var fields = data.fields;
    var rows   = data.rows || {};

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
    // id -> the object's displayed label (the first cell of its table row).
    function idToLabel() {
      var map = {};
      for (var i = 0; i < checks.length; i++) {
        var parts = (checks[i].name || '').split('__');
        var id    = parts[parts.length - 1];
        if (!/^\d+$/.test(id)) { continue; }
        var tr  = checks[i].closest ? checks[i].closest('tr') : null;
        var lbl = '';
        if (tr) {
          var a = tr.querySelector('td a');
          lbl = a ? a.textContent : (tr.querySelector('td') ? tr.querySelector('td').textContent : '');
        }
        map[id] = (lbl && lbl.replace(/\s+/g, ' ').trim()) || (rows[id] && rows[id].name) || id;
      }
      return map;
    }
    function fieldSpec(name) {
      for (var i = 0; i < fields.length; i++) { if (fields[i].name === name) { return fields[i]; } }
      return null;
    }
    // Build an editable input for a field spec, pre-filled with the current value.
    function makeInput(spec, cur) {
      cur = (cur === undefined || cur === null) ? '' : cur;
      if (spec.kind === 'checkbox') {
        var c = document.createElement('input');
        c.type = 'checkbox';
        c.checked = (cur === true || cur === 1 || cur === '1');
        return c;
      }
      if (spec.kind === 'fk') {
        if (!spec.options) {   // large target: no dropdown, edit by id
          var t = document.createElement('input');
          t.type = 'text'; t.value = cur;
          return t;
        }
        var sel = document.createElement('select');
        var o0 = document.createElement('option');
        o0.value = ''; o0.textContent = '\u2014';   // em dash = clear
        sel.appendChild(o0);
        var opts = spec.options;
        for (var i = 0; i < opts.length; i++) {
          var o = document.createElement('option');
          o.value = opts[i].id; o.textContent = opts[i].label;
          sel.appendChild(o);
        }
        sel.value = (cur === '' || cur === 0) ? '' : String(cur);
        if (sel.value === '') {   // current FK not in the (small) option list -> id box
          var t2 = document.createElement('input');
          t2.type = 'text'; t2.value = cur;
          return t2;
        }
        return sel;
      }
      if (spec.kind === 'textarea') {
        var ta = document.createElement('textarea');
        ta.value = cur; ta.rows = 2;
        return ta;
      }
      var inp = document.createElement('input');
      if (spec.kind === 'number') { inp.type = 'text'; inp.setAttribute('data-nd-int', '1'); }
      else if (spec.kind === 'date') { inp.type = 'date'; }
      else { inp.type = 'text'; }
      inp.value = cur;
      return inp;
    }
    // Extract a value from an editable input, mirroring collect(): checkbox ->
    // bool, FK (select or id box) -> id or null, number -> int, else string.
    function cellValue(spec, el) {
      if (spec.kind === 'checkbox') { return el.checked; }
      if (spec.kind === 'fk') { return el.value === '' ? null : el.value; }
      if (spec.kind === 'number') { return /^\d+$/.test(el.value) ? parseInt(el.value, 10) : el.value; }
      return el.value;
    }
    // Set a cell input to a value (used by the "apply to all" row).
    function setCell(el, spec, v) {
      if (!el) { return; }
      if (spec.kind === 'checkbox') { el.checked = (v === true || v === 1); }
      else { el.value = (v === null || v === undefined) ? '' : v; }
    }

    // Modal wrapper (reuses the .nd-modal-ov / .nd-modal overlay + card).
    // full=true stretches the card to the whole viewport (the wide edit table);
    // the field picker uses the compact default.
    function openModal(title, full) {
      var ov = document.createElement('div');
      ov.className = 'nd-modal-ov' + (full ? ' nd-full-ov' : '');
      var card = document.createElement('div');
      card.className = 'nd-modal nd-bulk' + (full ? ' nd-full' : '');
      var h = document.createElement('div');
      h.className = 'nd-modal-msg';
      h.textContent = title;
      h.style.cssText = 'font-weight:600;font-size:1.05em;margin-bottom:0.4em';
      card.appendChild(h);
      ov.appendChild(card);
      document.body.appendChild(ov);
      function close() { if (ov.parentNode) { ov.parentNode.removeChild(ov); } }
      ov.addEventListener('click', function (e) { if (e.target === ov) { close(); } });
      return { ov: ov, card: card, close: close };
    }
    function buttonRow(container, okLabel, onOk, onCancel) {
      var row = document.createElement('div');
      row.className = 'nd-modal-row';
      var ok = document.createElement('button');
      ok.type = 'button'; ok.className = 'btn nd-modal-create'; ok.textContent = okLabel;
      var cancel = document.createElement('button');
      cancel.type = 'button'; cancel.className = 'btn'; cancel.textContent = 'Cancel';
      ok.addEventListener('click', onOk);
      cancel.addEventListener('click', onCancel);
      row.appendChild(ok); row.appendChild(cancel);
      container.appendChild(row);
      return { ok: ok, cancel: cancel };
    }

    // ---- Stage 1: field picker (which fields to edit) ----
    function fieldPicker(ids, labels, done) {
      var m = openModal('Bulk edit \u2014 choose fields to change');
      var body = document.createElement('div');
      body.className = 'nd-bulk-body';
      var wrap = document.createElement('div');
      wrap.className = 'nd-bulk-fields';
      for (var i = 0; i < fields.length; i++) {
        var f = fields[i];
        var lbl = document.createElement('label');
        var cb = document.createElement('input');
        cb.type = 'checkbox'; cb.value = f.name;
        lbl.appendChild(cb);
        lbl.appendChild(document.createTextNode(' ' + f.tag));
        wrap.appendChild(lbl);
      }
      body.appendChild(wrap);
      m.card.appendChild(body);
      var note = document.createElement('div');
      note.style.cssText = 'color:#666;font-size:0.85em;margin:0.5em 0 0.2em';
      note.textContent = ids.length + ' object(s) selected.';
      m.card.appendChild(note);
      var buttons = buttonRow(m.card, 'Continue', function () {
        var chosen = [];
        var cbs = body.querySelectorAll('input[type=checkbox]');
        for (var k = 0; k < cbs.length; k++) { if (cbs[k].checked) { chosen.push(cbs[k].value); } }
        if (!chosen.length) { status(false, 'Choose at least one field to edit.', 4000); return; }
        m.close();
        editTable(ids, labels, chosen, done);
      }, function () { m.close(); });
      buttons.ok.focus();
    }

    // ---- Stage 2: editable table (chosen fields, pre-filled, + apply-to-all) ----
    function editTable(ids, labels, chosen, done) {
      var m = openModal('Bulk edit \u2014 ' + ids.length + ' object(s)', true);
      var body = document.createElement('div');
      body.className = 'nd-bulk-body';
      var table = document.createElement('table');
      table.className = 'nd-bulk-table';

      // Header row (Name + each chosen field).
      var htr = document.createElement('tr');
      var th0 = document.createElement('th'); th0.textContent = 'Name';
      htr.appendChild(th0);
      var specs = [];
      for (var i = 0; i < chosen.length; i++) {
        var spec = fieldSpec(chosen[i]);
        if (!spec) { continue; }
        specs.push(spec);
        var th = document.createElement('th'); th.textContent = spec.tag;
        htr.appendChild(th);
      }
      table.appendChild(htr);

      // "Apply to all" row: per field, a value box + a checkbox that copies it
      // into every row for that field (one value for the whole selection).
      var atr = document.createElement('tr');
      atr.className = 'nd-bulk-apply';
      var ath0 = document.createElement('th'); ath0.textContent = 'Apply to all';
      atr.appendChild(ath0);
      var applyCtrls = [];
      for (var a = 0; a < specs.length; a++) {
        var s = specs[a];
        var td = document.createElement('td');
        var av = makeInput(s, '');
        var acb = document.createElement('input');
        acb.type = 'checkbox';
        acb.style.cssText = 'width:auto;margin-left:4px';
        acb.title = 'Apply this value to all rows';
        td.appendChild(av); td.appendChild(acb);
        atr.appendChild(td);
        applyCtrls.push({ spec: s, value: av, check: acb });
      }
      table.appendChild(atr);

      // One row per selected object, pre-filled with the current value.
      var rowCtrls = [];   // { id, cells: {field: inputEl} }
      for (var r = 0; r < ids.length; r++) {
        var id = ids[r];
        var tr = document.createElement('tr');
        var nameTd = document.createElement('td');
        nameTd.textContent = labels[id] || id;
        nameTd.style.cssText = 'font-weight:600;white-space:nowrap';
        tr.appendChild(nameTd);
        var cells = {};
        for (var b = 0; b < specs.length; b++) {
          var sp = specs[b];
          var td2 = document.createElement('td');
          var cur = rows[id] ? rows[id][sp.name] : '';
          var el = makeInput(sp, cur);
          cells[sp.name] = el;
          td2.appendChild(el);
          tr.appendChild(td2);
        }
        table.appendChild(tr);
        rowCtrls.push({ id: id, cells: cells });
      }
      body.appendChild(table);
      m.card.appendChild(body);

      // Wire "apply to all": copy the apply value into every row for that field.
      for (var p = 0; p < applyCtrls.length; p++) {
        (function (ac) {
          function apply() {
            if (!ac.check.checked) { return; }
            var v = cellValue(ac.spec, ac.value);
            for (var q = 0; q < rowCtrls.length; q++) {
              setCell(rowCtrls[q].cells[ac.spec.name], ac.spec, v);
            }
          }
          ac.check.addEventListener('change', apply);
          ac.value.addEventListener('change', apply);
        })(applyCtrls[p]);
      }

      var buttons = buttonRow(m.card, 'Save changes', function () {
        var updates = [];
        for (var u = 0; u < rowCtrls.length; u++) {
          var rc = rowCtrls[u];
          var entry = { id: rc.id };
          for (var w = 0; w < specs.length; w++) {
            entry[specs[w].name] = cellValue(specs[w], rc.cells[specs[w].name]);
          }
          updates.push(entry);
        }
        if (!updates.length) { status(false, 'Nothing to save.', 4000); return; }
        buttons.ok.disabled = true;
        spinner(true, 'Saving ' + updates.length + ' object(s)\u2026');
        api('POST', data.api, { updates: updates }).then(function (res) {
          spinner(false);
          if (res.ok) {
            var d = res.data || {};
            var nDone = (d.updated && d.updated.length) || 0;
            var errs = d.errors || {};
            var nErr = Object.keys(errs).length;
            var msg = 'Updated ' + nDone + ' object(s)';
            if (nErr) {
              msg += ', ' + nErr + ' error(s): ' +
                Object.keys(errs).map(function (k) { return k + ': ' + errs[k]; }).join('; ');
            }
            status(nErr ? (nDone > 0) : true, msg, nErr ? 8000 : undefined);
            if (!nErr) { m.close(); done(true); }
            else { buttons.ok.disabled = false; }
          } else {
            buttons.ok.disabled = false;
            status(false, errMsg(res), 8000);
          }
        });
      }, function () { m.close(); });
      buttons.ok.focus();
    }

    for (var j = 0; j < btns.length; j++) {
      btns[j].addEventListener('click', function () {
        var ids = checkedIds();
        if (!ids.length) { status(false, 'Select at least one row to edit.', 4000); return; }
        fieldPicker(ids, idToLabel(), function (ok) {
          if (ok) { setTimeout(function () { location.reload(); }, 700); }
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

  // "Create block/IP" modal (Mason ADD_BLOCK): shown when clicking a free partition
  // (container view) or an unassigned address (subnet view). Confirms the creation of
  // a not-yet-existing IP address or block and lets the user pick the status —
  // block: Container/Reserved/Subnet (default Container); address: Static/Reserved
  // (+ Dynamic when the Subnet parent has DHCP). POSTs /api/ipblock, then goes to the
  // new block's detail page.
  function ndCreateIpblock(opts) {
    var parts  = opts.address.split('/');
    var prefix = parts.length > 1 ? parseInt(parts[1], 10) : (parts[0].indexOf(':') >= 0 ? 128 : 32);
    var isAddr = (prefix === 32 || prefix === 128);
    var statuses = isAddr
      ? (['Static', 'Reserved'].concat(opts.dhcp ? ['Dynamic'] : []))
      : ['Container', 'Reserved', 'Subnet'];
    var defStatus = isAddr ? 'Static' : 'Container';
    // API base derives from the page URL (…/<prefix>/management/… → <prefix>/api/ipblock);
    // the API auto-attaches the new block to its parent, so no `parent` in the body.
    var webPrefix = location.pathname.split('/management')[0];
    return new Promise(function (resolve) {
      var ov = document.createElement('div'); ov.className = 'nd-modal-ov';
      var card = document.createElement('div'); card.className = 'nd-modal';
      var msg = document.createElement('div'); msg.className = 'nd-modal-msg';
      msg.textContent = 'The IP address or block ' + opts.address + ' does not yet exist. Are you sure that you want to create it?';
      card.appendChild(msg);
      var selWrap = document.createElement('div'); selWrap.className = 'nd-modal-field';
      var sel = document.createElement('select'); sel.className = 'nd-modal-select';
      for (var i = 0; i < statuses.length; i++) {
        var op = document.createElement('option');
        op.value = statuses[i]; op.textContent = statuses[i];
        if (statuses[i] === defStatus) { op.selected = true; }
        sel.appendChild(op);
      }
      selWrap.appendChild(sel);
      card.appendChild(selWrap);
      var row = document.createElement('div'); row.className = 'nd-modal-row';
      var okBtn = document.createElement('button'); okBtn.type = 'button'; okBtn.className = 'btn nd-modal-create'; okBtn.textContent = 'Create';
      var cancelBtn = document.createElement('button'); cancelBtn.type = 'button'; cancelBtn.className = 'btn'; cancelBtn.textContent = 'Cancel';
      row.appendChild(okBtn); row.appendChild(cancelBtn); card.appendChild(row);
      ov.appendChild(card); document.body.appendChild(ov); okBtn.focus();
      function close() {
        document.removeEventListener('keydown', onKey, true);
        if (ov.parentNode) { ov.parentNode.removeChild(ov); }
      }
      function onKey(e) { if (e.key === 'Escape') { close(); resolve({ ok: false }); } }
      document.addEventListener('keydown', onKey, true);
      okBtn.addEventListener('click', function () {
        var st = sel.value;
        okBtn.disabled = true;
        spinner(true, 'Creating ' + opts.address + '…');
        api('POST', webPrefix + '/api/ipblock', { address: opts.address, status: st }).then(function (res) {
          spinner(false);
          if (res.ok) {
            // Go to the new block's detail page so the user can add info (description,
            // DNS A/AAAA record for a hostname, owner, …) right away.
            close(); status(true, 'Created');
            var pid = res.data && res.data.id;
            setTimeout(function () { location.href = pid ? webPrefix + '/management/ipblock/' + pid : location.href.replace(/[?#].*$/, ''); }, 600);
            resolve({ ok: true });
          }
          else { close(); status(false, errMsg(res), 8000); resolve({ ok: false }); }
        });
      });
      cancelBtn.addEventListener('click', function () { close(); resolve({ ok: false }); });
      ov.addEventListener('click', function (e) { if (e.target === ov) { close(); resolve({ ok: false }); } });
    });
  }

  // Clickable free cells — container free partitions + subnet unassigned addresses —
  // open the "create block/IP" modal above.
  function initCreateBlocks() {
    var cells = document.querySelectorAll('[data-nd-create]');
    for (var i = 0; i < cells.length; i++) {
      cells[i].addEventListener('click', function (e) {
        e.preventDefault();
        var cidr = this.getAttribute('data-nd-create');
        if (!cidr) { return; }
        ndCreateIpblock({
          address: cidr,
          dhcp:    this.getAttribute('data-nd-dhcp') === '1'
        });
      });
    }
  }

  // Access Rights tab: "Add rights" form (nd-rights-add) POSTs to /api/accessright
  // with {object_class, object_id, subject_type, subject_id, rights:[...]}.
  // "Remove" buttons (nd-rights-del) DELETE /api/userright/<id> or /api/groupright/<id>.
  function initRights() {
    var form = document.querySelector('form.nd-rights-add');
    if (form) {
      form.addEventListener('submit', function (e) {
        e.preventDefault();
        var url = form.getAttribute('data-nd-api');
        var objClass = form.getAttribute('data-nd-object-class');
        var objId = parseInt(form.getAttribute('data-nd-object-id'), 10);
        var sel = form.querySelector('select[name=subject]');
        var val = sel ? sel.value : '';
        if (!val) { status(false, 'Select a subject.', 4000); return; }
        var parts = val.split(':');
        var subjectType = parts[0];
        var subjectId = parseInt(parts[1], 10);
        var rights = [];
        var cbs = form.querySelectorAll('input[name=access]:checked');
        for (var i = 0; i < cbs.length; i++) { rights.push(cbs[i].value); }
        if (!rights.length) { status(false, 'Select at least one right.', 4000); return; }
        var body = {
          object_class: objClass,
          object_id: objId,
          subject_type: subjectType,
          subject_id: subjectId,
          rights: rights
        };
        var btn = form.querySelector('button[type=submit]');
        if (btn) { btn.disabled = true; }
        api('POST', url, body).then(function (res) {
          if (res.ok) {
            status(true, 'Access rights updated.');
            setTimeout(function () { location.reload(); }, 700);
          } else {
            status(false, errMsg(res), 8000);
            if (btn) { btn.disabled = false; }
          }
        });
      });
    }
    var dels = document.querySelectorAll('.nd-rights-del');
    for (var d = 0; d < dels.length; d++) {
      dels[d].addEventListener('click', function (e) {
        e.preventDefault();
        var url = this.getAttribute('data-nd-api');
        var btn = this;
        btn.disabled = true;
        api('DELETE', url).then(function (res) {
          if (res.ok) {
            status(true, 'Access right removed.');
            setTimeout(function () { location.reload(); }, 700);
          } else {
            status(false, errMsg(res), 8000);
            btn.disabled = false;
          }
        });
      });
    }
    var secDels = document.querySelectorAll('.nd-sec-del');
    for (var s = 0; s < secDels.length; s++) {
      secDels[s].addEventListener('click', function (e) {
        e.preventDefault();
        var url = this.getAttribute('data-nd-api');
        var btn = this;
        btn.disabled = true;
        api('DELETE', url).then(function (res) {
          if (res.ok) {
            status(true, 'Removed.');
            setTimeout(function () { location.reload(); }, 700);
          } else {
            status(false, errMsg(res), 8000);
            btn.disabled = false;
          }
        });
      });
    }
  }

  // Range mode: click "Range" button → select IPs on the grid (mousedown=start,
  // mouseup=end), a side panel shows the form, submit creates the range via API.
  function initRange() {
    var btn = document.getElementById('nd-range-btn');
    if (!btn) { return; }
    var data = window.ND_RANGE_DATA || {};
    var entities = data.entities || [];
    var fzones = data.fzones || [];
    var defaultFzone = String(data.fzoneDefault || '');
    var defaultDnsPrefix = data.dnsPrefix || '';
    var defaultDnsSuffix = data.dnsSuffix || '';
    var apiUrl = btn.getAttribute('data-nd-range-api');
    var grid = document.querySelector('table.ipgrid');

    var active = false, selStart = null, selEnd = null, dragging = false;
    var panel = null;

    function cellIp(el) {
      var target = el.closest('[data-nd-ip]');
      return target ? target.getAttribute('data-nd-ip') : null;
    }

    function highlightRange(ip1, ip2) {
      if (!grid) { return; }
      clearHighlight();
      if (!ip1 || !ip2) { return; }
      var n1 = ip2ipv4(ip1), n2 = ip2ipv4(ip2);
      if (n1 === null || n2 === null) { return; }
      var lo = Math.min(n1, n2), hi = Math.max(n1, n2);
      var cells = grid.querySelectorAll('[data-nd-ip]');
      for (var i = 0; i < cells.length; i++) {
        var n = ip2ipv4(cells[i].getAttribute('data-nd-ip'));
        if (n !== null && n >= lo && n <= hi) {
          var inner = cells[i].querySelector('div');
          if (inner) { inner.classList.add('ipaddr-range-selected'); }
        }
      }
    }

    function clearHighlight() {
      if (!grid) { return; }
      var sel = grid.querySelectorAll('.ipaddr-range-selected');
      for (var i = 0; i < sel.length; i++) { sel[i].classList.remove('ipaddr-range-selected'); }
    }

    function buildPanel(start, end) {
      if (panel) { panel.remove(); }
      panel = document.createElement('div');
      panel.className = 'nd-range-panel';
      var ownerOpts = '<option value="">--SELECT--</option>';
      for (var i = 0; i < entities.length; i++) {
        ownerOpts += '<option value="' + entities[i][0] + '">' + entities[i][1] + '</option>';
      }
      var fzoneOpts = '<option value="">--SELECT--</option>';
      for (var i = 0; i < fzones.length; i++) {
        var sel = (String(fzones[i][0]) === String(defaultFzone)) ? ' selected' : '';
        fzoneOpts += '<option value="' + fzones[i][0] + '"' + sel + '>' + fzones[i][1] + '</option>';
      }
      panel.innerHTML =
        '<h4 class="nd-range-drag">IP Range <span class="nd-range-close" id="nd-r-close">&times;</span></h4>' +
        '<p class="nd-range-info" id="nd-r-info">' + (start || '?') + ' \u2192 ' + (end || '?') + '</p>' +
        '<label>Start IP</label><input id="nd-r-start" type="text" value="' + (start || '') + '">' +
        '<label>End IP</label><input id="nd-r-end" type="text" value="' + (end || '') + '">' +
        '<label>Status</label>' +
        '<select id="nd-r-status">' +
        '<option value="">--SELECT--</option>' +
        '<option value="Static">Static</option>' +
        '<option value="Reserved">Reserved</option>' +
        '<option value="Dynamic">Dynamic</option>' +
        '</select>' +
        '<label>Owner</label><select id="nd-r-owner">' + ownerOpts + '</select>' +
        '<label>Used By</label><select id="nd-r-usedby">' + ownerOpts + '</select>' +
        '<label>Description</label><input id="nd-r-desc" type="text">' +
        '<label><input id="nd-r-dns" type="checkbox" style="width:auto"> Auto-generate DNS</label>' +
        '<label>DNS prefix</label><input id="nd-r-prefix" type="text" placeholder="e.g. host" value="' + defaultDnsPrefix + '">' +
        '<label>DNS suffix</label><input id="nd-r-suffix" type="text" value="' + defaultDnsSuffix + '">' +
        '<label>Forward Zone</label><select id="nd-r-fzone">' + fzoneOpts + '</select>' +
        '<div class="nd-range-actions">' +
        '<button type="button" class="btn" id="nd-r-create">Create</button>' +
        '<button type="button" class="btn" id="nd-r-cancel">Cancel</button>' +
        '</div>';
      document.body.appendChild(panel);
      // Draggable by the header.
      var dragEl = panel.querySelector('.nd-range-drag');
      var dragStart = null;
      dragEl.addEventListener('mousedown', function (e) {
        if (e.target.id === 'nd-r-close') { return; }
        e.preventDefault();
        var rect = panel.getBoundingClientRect();
        dragStart = { x: e.clientX - rect.left, y: e.clientY - rect.top };
        panel.style.transform = 'none';
        panel.style.left = rect.left + 'px';
        panel.style.top = rect.top + 'px';
        function onMove(ev) {
          panel.style.left = (ev.clientX - dragStart.x) + 'px';
          panel.style.top = (ev.clientY - dragStart.y) + 'px';
        }
        function onUp() {
          document.removeEventListener('mousemove', onMove);
          document.removeEventListener('mouseup', onUp);
        }
        document.addEventListener('mousemove', onMove);
        document.addEventListener('mouseup', onUp);
      });
      document.getElementById('nd-r-close').addEventListener('click', closeRange);
      document.getElementById('nd-r-create').addEventListener('click', function () {
        var s = document.getElementById('nd-r-start').value.trim();
        var en = document.getElementById('nd-r-end').value.trim();
        var st = document.getElementById('nd-r-status').value;
        if (!s || !en) { status(false, 'Enter start and end IPs.', 3000); return; }
        if (!st) { status(false, 'Select a status.', 3000); return; }
        // Ensure start <= end (numeric).
        var n1 = ip2ipv4(s), n2 = ip2ipv4(en);
        if (n1 !== null && n2 !== null && n1 > n2) { var t = s; s = en; en = t; }
        var body = { start: s, end: en, status: st };
        var own = document.getElementById('nd-r-owner').value;
        if (own) { body.owner = parseInt(own, 10); }
        var ub = document.getElementById('nd-r-usedby').value;
        if (ub) { body.used_by = parseInt(ub, 10); }
        var desc = document.getElementById('nd-r-desc').value;
        if (desc) { body.description = desc; }
        if (document.getElementById('nd-r-dns').checked) { body.gen_dns = true; }
        var np = document.getElementById('nd-r-prefix').value;
        if (np) { body.name_prefix = np; }
        var ns = document.getElementById('nd-r-suffix').value;
        if (ns) { body.name_suffix = ns; }
        var fz = document.getElementById('nd-r-fzone').value;
        if (fz) { body.fzone = parseInt(fz, 10); }
        var cb = document.getElementById('nd-r-create');
        cb.disabled = true;
        api('POST', apiUrl, body).then(function (res) {
          if (res.ok) {
            status(true, 'Range created (' + res.data.created + ' IPs).');
            closeRange();
            setTimeout(function () { location.reload(); }, 700);
          } else {
            status(false, errMsg(res), 8000);
            cb.disabled = false;
          }
        });
      });
      document.getElementById('nd-r-cancel').addEventListener('click', closeRange);
      // Sync info + highlight when start/end are edited manually.
      function syncFromInputs() {
        var s = document.getElementById('nd-r-start').value.trim();
        var en = document.getElementById('nd-r-end').value.trim();
        var info = document.getElementById('nd-r-info');
        if (s && en) {
          var n1 = ip2ipv4(s), n2 = ip2ipv4(en);
          if (n1 !== null && n2 !== null) {
            var lo = n1 <= n2 ? s : en;
            var hi = n1 <= n2 ? en : s;
            info.textContent = lo + ' \u2192 ' + hi + ' (' + countRange(lo, hi) + ' IPs)';
            highlightRange(s, en);
          } else {
            info.textContent = s + ' \u2192 ' + en;
            clearHighlight();
          }
        } else {
          info.textContent = (s || '?') + ' \u2192 ' + (en || '?');
          clearHighlight();
        }
      }
      document.getElementById('nd-r-start').addEventListener('input', syncFromInputs);
      document.getElementById('nd-r-end').addEventListener('input', syncFromInputs);
    }

    function countRange(ip1, ip2) {
      var a = ip2ipv4(ip1), b = ip2ipv4(ip2);
      if (a === null || b === null) { return '?'; }
      var lo = Math.min(a, b), hi = Math.max(a, b);
      return (hi - lo + 1);
    }

    function ip2ipv4(ip) {
      var parts = ip.split('.');
      if (parts.length !== 4) { return null; }
      var n = 0;
      for (var i = 0; i < 4; i++) { n = n * 256 + parseInt(parts[i], 10); }
      return n;
    }

    function closeRange() {
      active = false;
      dragging = false;
      selStart = null; selEnd = null;
      clearHighlight();
      if (grid) { grid.classList.remove('nd-range-mode'); }
      if (panel) { panel.remove(); panel = null; }
    }

    if (grid) {
      grid.addEventListener('mousedown', function (e) {
        if (!active) { return; }
        e.preventDefault();
        var ip = cellIp(e.target);
        if (!ip) { return; }
        dragging = true;
        selStart = ip; selEnd = ip;
        highlightRange(ip, ip);
        if (panel) {
          panel.querySelector('#nd-r-start').value = ip;
          panel.querySelector('#nd-r-end').value = ip;
          panel.querySelector('#nd-r-info').textContent = ip + ' \u2192 ' + ip + ' (1 IP)';
        }
      });

      grid.addEventListener('mouseover', function (e) {
        if (!active || !dragging) { return; }
        var ip = cellIp(e.target);
        if (!ip) { return; }
        selEnd = ip;
        var n1 = ip2ipv4(selStart), n2 = ip2ipv4(selEnd);
        var s = (n1 !== null && n2 !== null && n1 > n2) ? selEnd : selStart;
        var en = (n1 !== null && n2 !== null && n1 > n2) ? selStart : selEnd;
        highlightRange(s, en);
        if (panel) {
          panel.querySelector('#nd-r-start').value = s;
          panel.querySelector('#nd-r-end').value = en;
          panel.querySelector('#nd-r-info').textContent = s + ' \u2192 ' + en + ' (' + countRange(s, en) + ' IPs)';
        }
      });
    }

    document.addEventListener('mouseup', function (e) {
      if (!active || !dragging) { return; }
      dragging = false;
      if (selStart && selEnd && panel) {
        var n1 = ip2ipv4(selStart), n2 = ip2ipv4(selEnd);
        var s = (n1 !== null && n2 !== null && n1 > n2) ? selEnd : selStart;
        var en = (n1 !== null && n2 !== null && n1 > n2) ? selStart : selEnd;
        panel.querySelector('#nd-r-start').value = s;
        panel.querySelector('#nd-r-end').value = en;
        panel.querySelector('#nd-r-info').textContent = s + ' \u2192 ' + en + ' (' + countRange(s, en) + ' IPs)';
        highlightRange(s, en);
      }
    });

    btn.addEventListener('click', function () {
      if (active) { closeRange(); return; }
      active = true;
      if (grid) { grid.classList.add('nd-range-mode'); }
      buildPanel(
        btn.getAttribute('data-nd-range-first') || '',
        btn.getAttribute('data-nd-range-last') || ''
      );
    });
  }

  // Batch edit: "Batch Edit" button on the Children list → checkboxes on rows +
  // a panel with Status/Used By/Description/Delete. "Apply" submits via API.
  function initBatch() {
    var btn = document.getElementById('nd-batch-btn');
    if (!btn) { return; }
    var data = window.ND_BATCH_DATA || {};
    var statuses = data.statuses || [];
    var entities = data.entities || [];
    var table = btn.closest('.tabcard-body') ? btn.closest('.tabcard-body').querySelector('table.datatable') : null;
    if (!table) { table = document.querySelector('.tabcard-body table.datatable'); }
    if (!table) { return; }

    var active = false;
    var panel = null;
    var checkHeader = null;

    function addCheckboxes() {
      if (checkHeader) { return; }
      checkHeader = document.createElement('th');
      checkHeader.style.width = '30px';
      checkHeader.innerHTML = '<input type="checkbox" id="nd-batch-all">';
      table.querySelector('thead tr').prepend(checkHeader);
      var rows = table.querySelectorAll('tbody tr[data-nd-id]');
      for (var i = 0; i < rows.length; i++) {
        var td = document.createElement('td');
        td.innerHTML = '<input type="checkbox" class="nd-batch-chk" data-nd-id="' + rows[i].getAttribute('data-nd-id') + '">';
        rows[i].prepend(td);
      }
      document.getElementById('nd-batch-all').addEventListener('change', function () {
        var chks = table.querySelectorAll('.nd-batch-chk');
        for (var i = 0; i < chks.length; i++) { chks[i].checked = this.checked; }
      });
    }

    function removeCheckboxes() {
      if (checkHeader) { checkHeader.remove(); checkHeader = null; }
      var tds = table.querySelectorAll('tbody td:first-child input.nd-batch-chk');
      for (var i = 0; i < tds.length; i++) { tds[i].parentElement.remove(); }
    }

    function buildPanel() {
      if (panel) { panel.remove(); }
      panel = document.createElement('div');
      panel.className = 'nd-range-panel';
      var statusOpts = '<option value="">-- No change --</option>';
      for (var i = 0; i < statuses.length; i++) {
        statusOpts += '<option value="' + statuses[i][1] + '">' + statuses[i][1] + '</option>';
      }
      var entityOpts = '<option value="">-- No change --</option>';
      for (var i = 0; i < entities.length; i++) {
        entityOpts += '<option value="' + entities[i][0] + '">' + entities[i][1] + '</option>';
      }
      panel.innerHTML =
        '<h4 class="nd-range-drag">Batch Edit <span class="nd-range-close" id="nd-b-close">&times;</span></h4>' +
        '<label>Status</label><select id="nd-b-status">' + statusOpts + '</select>' +
        '<label>Owner</label><select id="nd-b-owner">' + entityOpts + '</select>' +
        '<label>Used By</label><select id="nd-b-usedby">' + entityOpts + '</select>' +
        '<label>Description</label><input id="nd-b-desc" type="text">' +
        '<label><input id="nd-b-del" type="checkbox" style="width:auto"> Delete selected</label>' +
        '<p class="nd-range-info" id="nd-b-info">0 selected</p>' +
        '<div class="nd-range-actions">' +
        '<button type="button" class="btn" id="nd-b-apply">Apply</button>' +
        '<button type="button" class="btn" id="nd-b-cancel">Cancel</button>' +
        '</div>';
      document.body.appendChild(panel);
      // Draggable.
      var dragEl = panel.querySelector('.nd-range-drag');
      var dragStart = null;
      dragEl.addEventListener('mousedown', function (e) {
        if (e.target.id === 'nd-b-close') { return; }
        e.preventDefault();
        var rect = panel.getBoundingClientRect();
        dragStart = { x: e.clientX - rect.left, y: e.clientY - rect.top };
        panel.style.transform = 'none';
        panel.style.left = rect.left + 'px';
        panel.style.top = rect.top + 'px';
        function onMove(ev) { panel.style.left = (ev.clientX - dragStart.x) + 'px'; panel.style.top = (ev.clientY - dragStart.y) + 'px'; }
        function onUp() { document.removeEventListener('mousemove', onMove); document.removeEventListener('mouseup', onUp); }
        document.addEventListener('mousemove', onMove);
        document.addEventListener('mouseup', onUp);
      });
      document.getElementById('nd-b-close').addEventListener('click', closeBatch);
      document.getElementById('nd-b-cancel').addEventListener('click', closeBatch);
      // Update selected count.
      var chks = table.querySelectorAll('.nd-batch-chk');
      function updateCount() {
        var n = 0;
        for (var i = 0; i < chks.length; i++) { if (chks[i].checked) { n++; } }
        var info = document.getElementById('nd-b-info');
        if (info) { info.textContent = n + ' selected'; }
      }
      for (var i = 0; i < chks.length; i++) { chks[i].addEventListener('change', updateCount); }

      document.getElementById('nd-b-apply').addEventListener('click', function () {
        var st = document.getElementById('nd-b-status').value;
        var own = document.getElementById('nd-b-owner').value;
        var ub = document.getElementById('nd-b-usedby').value;
        var desc = document.getElementById('nd-b-desc').value;
        var del = document.getElementById('nd-b-del').checked;
        var chks = table.querySelectorAll('.nd-batch-chk:checked');
        if (!chks.length) { status(false, 'Check at least one row.', 3000); return; }
        if (!del && !st && !own && !ub && !desc) { status(false, 'Nothing to apply.', 3000); return; }
        var cb = document.getElementById('nd-b-apply');
        cb.disabled = true;
        // One batch request for all checked rows (same endpoint as "Edit").
        var fields = {};
        if (st) { fields.status = st; }
        if (own) { fields.owner = parseInt(own, 10); }
        if (ub) { fields.used_by = parseInt(ub, 10); }
        if (desc) { fields.description = desc; }
        var updates = [], deletes = [];
        for (var i = 0; i < chks.length; i++) {
          var id = chks[i].getAttribute('data-nd-id');
          if (del) { deletes.push(id); }
          else {
            var u = { id: id };
            for (var k in fields) { u[k] = fields[k]; }
            updates.push(u);
          }
        }
        var prefix = location.pathname.split('/management')[0];
        api('POST', prefix + '/api/ipblock/batch', { updates: updates, deletes: deletes }).then(function (res) {
          cb.disabled = false;
          if (!res.ok) { status(false, errMsg(res), 6000); return; }
          var data = res.data || {};
          var nDone = ((data.updated && data.updated.length) || 0) + ((data.deleted && data.deleted.length) || 0);
          var errs = data.errors || {};
          var nErr = Object.keys(errs).length;
          var msg = nDone + ' row(s) ' + (del ? 'deleted' : 'updated');
          if (nErr) {
            msg += ', ' + nErr + ' error(s): ' + Object.keys(errs).map(function (k) { return k + ': ' + errs[k]; }).join('; ');
          }
          status(nErr ? nDone > 0 : true, msg, nErr ? 8000 : undefined);
          if (!nErr) {
            closeBatch();
            setTimeout(function () { location.reload(); }, 700);
          }
        });
      });
    }

    function closeBatch() {
      active = false;
      removeCheckboxes();
      if (panel) { panel.remove(); panel = null; }
    }

    btn.addEventListener('click', function () {
      if (active) { closeBatch(); return; }
      active = true;
      addCheckboxes();
      buildPanel();
    });
  }

  // Individual edit: "Edit" button on the Children list → inline editable cells
  // (status select, owner/used_by select, description text) + delete checkbox.
  // On Save, only dirty cells are POSTed. On Cancel, page reloads.
  function initEditChildren() {
    var btn = document.getElementById('nd-edit-children-btn');
    if (!btn) { return; }
    var data = window.ND_BATCH_DATA || {};
    var statuses = data.statuses || [];
    var entities = data.entities || [];
    var table = btn.closest('.tabcard-body') ? btn.closest('.tabcard-body').querySelector('table.datatable') : null;
    if (!table) { table = document.querySelector('.tabcard-body table.datatable'); }
    if (!table) { return; }

    var active = false;
    var saveBtn = null, cancelBtn = null, checkHeader = null;

    function makeSelect(options, currentVal, emptyText) {
      var sel = document.createElement('select');
      sel.style.cssText = 'width:100%;font-size:0.85em;padding:2px';
      var opt0 = document.createElement('option');
      opt0.value = '';
      opt0.textContent = emptyText || '—';   // "—" clears Owner/Used by; status uses "no change"
      sel.appendChild(opt0);
      for (var i = 0; i < options.length; i++) {
        var opt = document.createElement('option');
        opt.value = options[i][0];
        opt.textContent = options[i][1];
        if (String(options[i][0]) === String(currentVal) || options[i][1] === currentVal) { opt.selected = true; }
        sel.appendChild(opt);
      }
      return sel;
    }

    function makeTextInput(currentVal) {
      var inp = document.createElement('input');
      inp.type = 'text';
      inp.value = currentVal || '';
      inp.style.cssText = 'width:100%;font-size:0.85em;padding:2px';
      return inp;
    }

    function enterEditMode() {
      active = true;
      // Add delete checkbox column.
      checkHeader = document.createElement('th');
      checkHeader.style.width = '30px';
      checkHeader.innerHTML = '<input type="checkbox" id="nd-ed-all" title="Check all">';
      table.querySelector('thead tr').prepend(checkHeader);
      document.getElementById('nd-ed-all').addEventListener('change', function () {
        var chks = table.querySelectorAll('.nd-ed-del');
        for (var i = 0; i < chks.length; i++) { chks[i].checked = this.checked; }
      });
      // Transform cells.
      var rows = table.querySelectorAll('tbody tr[data-nd-id]');
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        // Delete checkbox.
        var tdDel = document.createElement('td');
        tdDel.innerHTML = '<input type="checkbox" class="nd-ed-del">';
        row.prepend(tdDel);
        // Find and transform editable cells.
        var tds = row.querySelectorAll('td[data-nd-st], td[data-nd-own], td[data-nd-ub], td[data-nd-desc]');
        for (var j = 0; j < tds.length; j++) {
          var td = tds[j];
          var orig = '';
          if (td.hasAttribute('data-nd-st')) {
            orig = td.getAttribute('data-nd-stid');   // current status id; "" if none
            td.innerHTML = '';
            td.appendChild(makeSelect(statuses, orig, '-- No change --'));
          } else if (td.hasAttribute('data-nd-own')) {
            orig = td.getAttribute('data-nd-own');
            td.innerHTML = '';
            td.appendChild(makeSelect(entities, orig));
          } else if (td.hasAttribute('data-nd-ub')) {
            orig = td.getAttribute('data-nd-ub');
            td.innerHTML = '';
            td.appendChild(makeSelect(entities, orig));
          } else if (td.hasAttribute('data-nd-desc')) {
            orig = td.getAttribute('data-nd-desc');
            td.innerHTML = '';
            td.appendChild(makeTextInput(orig));
          }
        }
      }
      // Save/Cancel buttons.
      var bar = document.createElement('div');
      bar.style.cssText = 'margin:0.5em 0;display:flex;gap:0.5em;align-items:center';
      bar.innerHTML = '<button type="button" class="btn" style="padding:4px 12px">Save</button>' +
                      '<button type="button" class="btn" style="padding:4px 12px">Cancel</button>' +
                      '<span style="color:#666;font-size:0.85em">Check = delete. "—" clears Owner/Used by; unchanged cells are not saved.</span>';
      table.parentElement.insertBefore(bar, table.nextSibling);
      saveBtn = bar.querySelector('button:first-child');
      cancelBtn = bar.querySelector('button:nth-child(2)');
      saveBtn.addEventListener('click', doSave);
      cancelBtn.addEventListener('click', function () { location.reload(); });
      btn.textContent = 'Done';
    }

    // Single request for the whole save (POST /api/ipblock/batch): the server
    // applies the updates + deletes and reports a per-id outcome, so there is
    // one consistent result to display and one reload.
    function doSave() {
      var rows = table.querySelectorAll('tbody tr[data-nd-id]');
      var updates = [], deletes = [];
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        var id = row.getAttribute('data-nd-id');
        var delChk = row.querySelector('.nd-ed-del');
        if (delChk && delChk.checked) { deletes.push(id); continue; }
        var body = {};
        // Collect DIRTY fields only: the batch endpoint writes exactly what is
        // sent, so the audit trail records only real changes.
        var tds = row.querySelectorAll('td[data-nd-st], td[data-nd-own], td[data-nd-ub], td[data-nd-desc]');
        for (var j = 0; j < tds.length; j++) {
          var td = tds[j];
          var el = td.querySelector('select, input');
          if (!el) { continue; }
          if (td.hasAttribute('data-nd-st')) {
            var stOrig = td.getAttribute('data-nd-stid');
            if (el.value && el.value !== stOrig) { body.status = el.value; }   // "" = no change
          } else if (td.hasAttribute('data-nd-own')) {
            var ownOrig = td.getAttribute('data-nd-own');
            if (el.value && el.value !== ownOrig) { body.owner = parseInt(el.value, 10); }
            else if (!el.value && ownOrig) { body.owner = null; }
          } else if (td.hasAttribute('data-nd-ub')) {
            var ubOrig = td.getAttribute('data-nd-ub');
            if (el.value && el.value !== ubOrig) { body.used_by = parseInt(el.value, 10); }
            else if (!el.value && ubOrig) { body.used_by = null; }
          } else if (td.hasAttribute('data-nd-desc')) {
            var descOrig = td.getAttribute('data-nd-desc') || '';
            if (el.value !== descOrig) { body.description = el.value; }
          }
        }
        if (Object.keys(body).length) { body.id = id; updates.push(body); }
      }
      if (!updates.length && !deletes.length) { status(false, 'No changes to save.', 3000); return; }
      var prefix = location.pathname.split('/management')[0];
      saveBtn.disabled = true;
      api('POST', prefix + '/api/ipblock/batch', { updates: updates, deletes: deletes }).then(function (res) {
        saveBtn.disabled = false;
        if (!res.ok) { status(false, errMsg(res), 6000); return; }
        var data = res.data || {};
        var nDone = ((data.updated && data.updated.length) || 0) + ((data.deleted && data.deleted.length) || 0);
        var errs = data.errors || {};
        var nErr = Object.keys(errs).length;
        var msg = nDone + ' row(s) saved';
        if (nErr) {
          msg += ', ' + nErr + ' error(s): ' + Object.keys(errs).map(function (k) { return k + ': ' + errs[k]; }).join('; ');
        }
        status(nErr ? nDone > 0 : true, msg, nErr ? 8000 : undefined);
        if (!nErr) { setTimeout(function () { location.reload(); }, 700); }
      });
    }

    btn.addEventListener('click', function () {
      if (active) { location.reload(); return; }
      enterEditMode();
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    initForms();
    initDhcpEnable();
    initToggle();
    initRecToggles();
    initRecDeletes();
    initAddForm();
    initFkSearch();
    initCreateBlocks();
    initRights();
    initRange();
    initBatch();
    initEditChildren();
    initBatchDelete();
    initBulkEdit();
  });

  window.ND = { api: api, status: status, collect: collect };
})();
