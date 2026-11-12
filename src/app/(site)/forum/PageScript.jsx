"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function ForumScript() {
  useEffect(() => {
    if (started) return;
    started = true;
    run();
  }, []);
  return null;
}

function run() {
const onReady = (fn) => fn();

onReady(function(){







  // =================================================================
  // The forum, on the server
  // =================================================================
  // rocodefest_forum was one array per browser, so this was a diary:
  // every visitor saw only their own threads and a reply reached
  // nobody. Posts and comments are rows now.
  //
  // Three things changed that are worth naming rather than leaving to
  // be discovered:
  //
  //   * Guest posting is gone. forum_posts.author_account_id is NOT
  //     NULL -- a post has an author with an account. The "Your name"
  //     box offered to signed-out visitors could never have produced a
  //     row.
  //   * Authorship is an account id, not a display name. The page
  //     compared names to decide who may edit a post, so two accounts
  //     sharing a name could edit each other's.
  //   * Attachments are not wired. forum_attachments records file
  //     metadata plus a storage_key pointing at a file store, and this
  //     project has no file store. The old chips were labelled "mock
  //     attachment -- no upload yet" and read no file content, so
  //     nothing is lost; the UI is removed rather than left offering
  //     something that cannot happen.

  function escapeHtml(s){ return (s || '').replace(/</g,'&lt;'); }

  var me = null;              // the signed-in account, or null
  var posts = [];             // posts in the current category
  var announcements = [];
  var comments = [];          // comments of the thread being viewed
  var currentCat = 'general';
  var viewingThread = null;

  function api(path, options){
    var opts = options || {};
    opts.credentials = 'same-origin';
    if(opts.body){ opts.headers = { 'Content-Type': 'application/json' }; opts.body = JSON.stringify(opts.body); }
    return fetch(path, opts).then(function(r){
      return r.json().catch(function(){ return {}; }).then(function(d){ return { ok: r.ok, status: r.status, d: d }; });
    });
  }

  function loadPosts(cat){
    return api('/api/forum/posts?category=' + encodeURIComponent(cat))
      .then(function(r){ posts = (r.d && r.d.posts) || []; })
      .catch(function(){ posts = []; });
  }
  function loadAnnouncements(){
    return api('/api/forum/posts?category=announcements')
      .then(function(r){ announcements = (r.d && r.d.posts) || []; })
      .catch(function(){ announcements = []; });
  }
  function loadComments(postId){
    return api('/api/forum/posts/' + postId + '/comments')
      .then(function(r){ comments = (r.d && r.d.comments) || []; })
      .catch(function(){ comments = []; });
  }

  // Only the author, and only what the server would also allow. This
  // decides whether to DRAW the buttons; the WHERE clauses on PATCH and
  // DELETE are what actually decide.
  function canManage(item){
    return !!(me && item && String(item.authorId) === String(me.id));
  }

  function renderComposerSessionLine(lineEl, nameInputEl){
    if(me){
      var roleLabel = me.role === 'club' ? 'Club' : (me.role === 'member' ? 'Membru' : (me.role === 'judge' ? 'Arbitru' : 'Partener'));
      var roleClass = me.role === 'club' ? 'role-club' : 'role-member';
      lineEl.innerHTML = 'Postezi ca <strong>' + escapeHtml(displayName(me)) + '</strong> ' +
        '<span class="role-tag ' + roleClass + '">' + roleLabel + '</span>';
      if(nameInputEl) nameInputEl.style.display = 'none';
    } else {
      // Signed-out visitors can read everything and post nothing. Saying
      // so is better than a composer that accepts text and then fails.
      lineEl.innerHTML = 'Autentifică-te ca să postezi — <a href="/login" style="text-decoration:underline;">intră în cont</a> sau <a href="/join-as" style="text-decoration:underline;">creează un cont</a>.';
      if(nameInputEl) nameInputEl.style.display = 'none';
    }
  }

  function displayName(account){
    return account.clubName || account.fullName || account.orgName || account.contactName || account.email;
  }

  // The avatar comes with the post now. It used to be looked up as
  // rocodefest_avatar_<author name> in the READER's own browser, which
  // meant a club only ever saw its own picture and nobody else's.
  function avatarHtml(item, sizeClass){
    sizeClass = sizeClass || '';
    var roleClass = item.authorRole === 'club' ? '' : 'role-member';
    var bgStyle = '';
    if(item.authorAvatar){ bgStyle = ' style="background-image:url(' + item.authorAvatar + ')"'; }
    var initial = (item.authorName || '?').trim().charAt(0).toUpperCase();
    return '<div class="post-avatar ' + roleClass + ' ' + sizeClass + '"' + bgStyle + '>' + (bgStyle ? '' : initial) + '</div>';
  }

  function whoHtml(item){
    var label = item.authorRole === 'club' ? 'Club'
              : item.authorRole === 'member' ? 'Membru'
              : item.authorRole === 'judge' ? 'Arbitru' : 'Partener';
    var cls = item.authorRole === 'club' ? 'role-club' : 'role-member';
    return '<div class="post-who"><span class="who-name">' + escapeHtml(item.authorName) + '</span>' +
           '<span class="who-meta"><span class="role-tag ' + cls + '">' + label + '</span></span></div>';
  }

  renderComposerSessionLine(document.getElementById('thread-session-line'), null);

  document.querySelectorAll('#forum-tabs .tab-btn').forEach(function(btn){
    btn.addEventListener('click', function(){
      document.querySelectorAll('#forum-tabs .tab-btn').forEach(function(b){ b.classList.remove('active'); });
      btn.classList.add('active');
      currentCat = btn.getAttribute('data-cat');
      viewingThread = null;
      loadPosts(currentCat).then(render);
    });
  });

  function renderAnnouncements(){
    var list = document.getElementById('announcements-list');
    if(announcements.length === 0){ list.innerHTML = '<p style="font-size:13px;color:var(--ink-soft);margin:0;">Niciun anunț încă.</p>'; return; }
    list.innerHTML = announcements.map(function(a){
      return '<div class="ann-item"><div class="thread-title">' + escapeHtml(a.title) + '</div><p class="thread-body" style="margin-top:4px;">' + escapeHtml(a.body || '') + '</p><div class="thread-meta">de ' + escapeHtml(a.authorName) + '</div></div>';
    }).join('');
  }

  // Announcements are the one category not open to everyone. There is
  // no organiser role in the schema yet, so the server allows judges
  // and this button follows that -- rather than offering a form whose
  // submission is refused.
  var annToggle = document.getElementById('new-announcement-toggle');
  if(me && me.role === 'judge'){
    annToggle.addEventListener('click', function(){
      var form = document.getElementById('announcement-form');
      form.style.display = form.style.display === 'none' ? 'block' : 'none';
    });
  } else {
    annToggle.style.display = 'none';
  }

  document.getElementById('post-announcement-btn').addEventListener('click', function(){
    var title = document.getElementById('new-ann-title').value.trim();
    var body = document.getElementById('new-ann-body').value.trim();
    if(!title) return;
    api('/api/forum/posts', { method: 'POST', body: { category: 'announcements', title: title, body: body } })
      .then(function(r){
        if(!r.ok){ alert(r.d.error || 'Anunțul nu a putut fi publicat.'); return; }
        document.getElementById('new-ann-title').value = '';
        document.getElementById('new-ann-body').value = '';
        document.getElementById('announcement-form').style.display = 'none';
        return loadAnnouncements().then(renderAnnouncements);
      });
  });

  var postThreadBtn = document.getElementById('post-thread-btn');
  postThreadBtn.addEventListener('click', function(){
    var title = document.getElementById('new-thread-title').value.trim();
    var body = document.getElementById('new-thread-body').value.trim();
    if(!title) return;
    if(!me){ window.location.href = '/login'; return; }
    postThreadBtn.disabled = true;
    api('/api/forum/posts', { method: 'POST', body: { category: currentCat, title: title, body: body } })
      .then(function(r){
        postThreadBtn.disabled = false;
        if(!r.ok){ alert(r.d.error || 'Subiectul nu a putut fi publicat.'); return; }
        document.getElementById('new-thread-title').value = '';
        document.getElementById('new-thread-body').value = '';
        return loadPosts(currentCat).then(render);
      })
      .catch(function(){ postThreadBtn.disabled = false; });
  });

  function openThreadEdit(t){
    var slot = document.getElementById('thread-edit-slot');
    slot.innerHTML =
      '<div class="edit-box">' +
        '<div class="field"><label>Titlu</label><input id="edit-thread-title" value="' + (t.title||'').replace(/"/g,'&quot;') + '"></div>' +
        '<div class="field"><label>Text</label><textarea id="edit-thread-body" rows="3">' + escapeHtml(t.body || '') + '</textarea></div>' +
        '<div style="display:flex;gap:10px;"><button class="btn btn-primary btn-small" id="save-thread-edit">Salvează</button><button class="btn btn-secondary btn-small" id="cancel-thread-edit">Renunță</button></div>' +
      '</div>';
    document.getElementById('cancel-thread-edit').addEventListener('click', function(){ render(); });
    document.getElementById('save-thread-edit').addEventListener('click', function(){
      var newTitle = document.getElementById('edit-thread-title').value.trim();
      if(!newTitle) return;
      api('/api/forum/posts/' + t.id, {
        method: 'PATCH',
        body: { title: newTitle, body: document.getElementById('edit-thread-body').value.trim() }
      }).then(function(r){
        if(!r.ok){ alert(r.d.error || 'Nu s-a putut salva.'); return; }
        return loadPosts(currentCat).then(render);
      });
    });
  }

  function openReplyEdit(id){
    var c = comments.filter(function(x){ return String(x.id) === String(id); })[0];
    var card = document.querySelector('.reply-card[data-ridx="' + id + '"]');
    if(!card || !c) return;
    var box = document.createElement('div');
    box.className = 'edit-box';
    box.innerHTML =
      '<div class="field"><label>Răspuns</label><textarea class="edit-reply-body" rows="2">' + escapeHtml(c.body || '') + '</textarea></div>' +
      '<div style="display:flex;gap:10px;"><button class="btn btn-primary btn-small save-reply-edit">Salvează</button><button class="btn btn-secondary btn-small cancel-reply-edit">Renunță</button></div>';
    card.appendChild(box);
    card.querySelector('.cancel-reply-edit').addEventListener('click', function(){ render(); });
    card.querySelector('.save-reply-edit').addEventListener('click', function(){
      var newBody = card.querySelector('.edit-reply-body').value.trim();
      if(!newBody) return;
      api('/api/forum/comments/' + id, { method: 'PATCH', body: { body: newBody } })
        .then(function(r){
          if(!r.ok){ alert(r.d.error || 'Nu s-a putut salva.'); return; }
          return loadComments(viewingThread).then(render);
        });
    });
  }

  function renderDetail(){
    var wrap = document.getElementById('threads-list');
    var t = posts.filter(function(x){ return String(x.id) === String(viewingThread); })[0];
    if(!t){ viewingThread = null; render(); return; }

    var canManageThread = canManage(t);
    var threadActions = canManageThread ? '<div class="post-actions"><button class="link-btn" id="thread-edit-btn">Editează</button><button class="link-btn danger" id="thread-delete-btn">Șterge</button></div>' : '';

    var repliesHtml = comments.map(function(r){
      var roleCls = r.authorRole === 'club' ? 'role-club' : 'role-member';
      var replyActions = canManage(r) && !r.isDeleted
        ? '<div class="post-actions"><button class="link-btn reply-edit-btn" data-idx="' + r.id + '">Editează</button><button class="link-btn danger reply-delete-btn" data-idx="' + r.id + '">Șterge</button></div>'
        : '';
      // A deleted comment keeps its place: its replies would otherwise
      // be answers to nothing.
      var text = r.isDeleted
        ? '<em style="opacity:0.6;">(șters)</em>'
        : escapeHtml(r.body) + (r.editedAt ? ' <em style="opacity:0.6;">(editat)</em>' : '');
      return '<div class="reply-card ' + roleCls + '" data-ridx="' + r.id + '">' +
        '<div class="post-head">' + avatarHtml(r, 'small') + whoHtml(r) + '</div>' +
        '<p>' + text + '</p>' +
        replyActions +
      '</div>';
    }).join('');

    wrap.innerHTML =
      '<div class="thread-detail-card">' +
        '<p style="font-size:12px;cursor:pointer;color:var(--coral-dark);font-weight:700;" id="back-btn">&larr; Înapoi la subiecte</p>' +
        '<div class="post-head">' + avatarHtml(t) + whoHtml(t) + '</div>' +
        '<h2 style="font-size:20px; margin-top:10px;">' + escapeHtml(t.title) + '</h2>' +
        '<p style="font-size:12px;color:var(--ink-soft);">' + new Date(t.createdAt).toLocaleDateString() + (t.editedAt ? ' &middot; editat' : '') + '</p>' +
        (t.body ? '<p style="margin-top:10px; white-space:pre-wrap;">' + escapeHtml(t.body) + '</p>' : '') +
        '<div id="thread-actions-wrap">' + threadActions + '</div>' +
        '<div id="thread-edit-slot"></div>' +
        '<div style="margin-top:16px;" id="replies-wrap">' + repliesHtml + '</div>' +
        '<div style="margin-top:16px;" id="reply-composer-wrap">' +
          '<p class="composer-session-line" id="reply-session-line"></p>' +
          (me ? '<div style="display:flex;gap:8px;flex-wrap:wrap;">' +
            '<input id="reply-body" placeholder="Write a reply..." style="flex:1; min-width:160px;">' +
            '<button class="btn btn-primary btn-small" id="reply-btn">Răspunde</button>' +
          '</div>' : '') +
        '</div>' +
      '</div>';

    document.getElementById('back-btn').addEventListener('click', function(){ viewingThread = null; render(); });
    renderComposerSessionLine(document.getElementById('reply-session-line'), null);

    var replyBtn = document.getElementById('reply-btn');
    if(replyBtn){
      replyBtn.addEventListener('click', function(){
        var body = document.getElementById('reply-body').value.trim();
        if(!body) return;
        replyBtn.disabled = true;
        api('/api/forum/posts/' + viewingThread + '/comments', { method: 'POST', body: { body: body } })
          .then(function(r){
            replyBtn.disabled = false;
            if(!r.ok){ alert(r.d.error || 'Răspunsul nu a putut fi trimis.'); return; }
            return Promise.all([loadComments(viewingThread), loadPosts(currentCat)]).then(render);
          })
          .catch(function(){ replyBtn.disabled = false; });
      });
    }

    if(canManageThread){
      document.getElementById('thread-delete-btn').addEventListener('click', function(){
        if(!confirm('Ștergi acest subiect? Acțiunea nu poate fi anulată.')) return;
        api('/api/forum/posts/' + viewingThread, { method: 'DELETE' })
          .then(function(r){
            if(!r.ok){ alert(r.d.error || 'Nu s-a putut șterge.'); return; }
            viewingThread = null;
            return loadPosts(currentCat).then(render);
          });
      });
      document.getElementById('thread-edit-btn').addEventListener('click', function(){ openThreadEdit(t); });
    }

    wrap.querySelectorAll('.reply-edit-btn').forEach(function(btn){
      btn.addEventListener('click', function(){ openReplyEdit(btn.getAttribute('data-idx')); });
    });
    wrap.querySelectorAll('.reply-delete-btn').forEach(function(btn){
      btn.addEventListener('click', function(){
        if(!confirm('Ștergi acest răspuns?')) return;
        api('/api/forum/comments/' + btn.getAttribute('data-idx'), { method: 'DELETE' })
          .then(function(r){
            if(!r.ok){ alert(r.d.error || 'Nu s-a putut șterge.'); return; }
            return loadComments(viewingThread).then(render);
          });
      });
    });
  }

  function render(){
    var wrap = document.getElementById('threads-list');
    var card = document.getElementById('new-thread-card');

    if(viewingThread){
      card.style.display = 'none';
      renderDetail();
      return;
    }

    card.style.display = 'block';
    var visible = posts.filter(function(p){ return !p.isDeleted; });
    if(visible.length === 0){ wrap.innerHTML = '<div class="empty-state">Niciun subiect în această categorie. Deschide unul mai sus!</div>'; return; }
    wrap.innerHTML = visible.map(function(t){
      var roleCls = t.authorRole === 'club' ? 'role-club' : 'role-member';
      return '<div class="thread-card ' + roleCls + '" data-id="' + t.id + '">' +
        '<div class="post-head">' + avatarHtml(t) + whoHtml(t) + '</div>' +
        '<div class="thread-title" style="margin-top:8px;">' + escapeHtml(t.title) + '</div>' +
        '<div class="thread-meta">' + new Date(t.createdAt).toLocaleDateString() + ' &middot; ' + t.commentCount + ' replies</div>' +
        (t.body ? '<div class="thread-body">' + escapeHtml(t.body).substring(0,120) + '</div>' : '') +
      '</div>';
    }).join('');
    wrap.querySelectorAll('.thread-card').forEach(function(cardEl){
      cardEl.addEventListener('click', function(){
        viewingThread = cardEl.getAttribute('data-id');
        loadComments(viewingThread).then(render);
      });
    });
  }

  // One bootstrap. Everything above needs to know who is here before it
  // can decide what to draw -- which composer to show, whose posts carry
  // Edit buttons -- so the page waits for /auth/me rather than drawing
  // twice.
  Promise.all([
    api('/auth/me').then(function(r){ me = (r.d && r.d.account) || null; }),
    loadAnnouncements()
  ])
    .then(function(){ return loadPosts(currentCat); })
    .then(function(){
      renderComposerSessionLine(document.getElementById('thread-session-line'), null);
      var annToggle2 = document.getElementById('new-announcement-toggle');
      if(annToggle2){ annToggle2.style.display = (me && me.role === 'judge') ? '' : 'none'; }
      renderAnnouncements();
      render();
    })
    .catch(function(){
      document.getElementById('threads-list').innerHTML =
        '<div class="empty-state">Forumul nu a putut fi încărcat. Reîncarcă pagina.</div>';
    });
  // TODO: placeholder — mock-only feedback so the button doesn't feel dead.
  // Real navigation to the regulations will replace this once the backend
  // serves rules content. Delegated on document since the reply composer's
  // button is re-created on every render().
  var rulesToastTimer = null;
  document.addEventListener('click', function(e){
    var btn = e.target.closest && e.target.closest('.rules-ref-btn');
    if(!btn) return;
    var toast = document.getElementById('fab-toast');
    if(!toast) return;
    toast.textContent = '📖 Doar machetă — va deschide regulamentul oficial după conectare';
    toast.classList.add('show');
    clearTimeout(rulesToastTimer);
    rulesToastTimer = setTimeout(function(){
      toast.classList.remove('show');
      setTimeout(function(){ toast.textContent = 'Link copiat!'; }, 300);
    }, 2200);
  });

});
}
