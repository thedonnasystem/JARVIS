'use strict';
const views = { home: 'v-home', feed: 'v-feed', about: 'v-about' };
document.querySelectorAll('nav button').forEach((b) => b.addEventListener('click', () => {
  const k = b.id.slice(2);
  document.querySelectorAll('.view').forEach((v) => v.classList.toggle('on', v.id === views[k]));
  document.querySelectorAll('nav button').forEach((x) => x.classList.toggle('on', x === b));
}));
const q = new URLSearchParams(location.search).get('q');
if (q) document.getElementById('q').textContent = q;
fetch('data.json').then((r) => r.json()).then((d) => { document.getElementById('fund').textContent = d.fund; document.getElementById('note').textContent = d.note; });
if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
