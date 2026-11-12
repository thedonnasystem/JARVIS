(function () {
  var URL_ = 'https://ihxzvpwbqydqtblvazbq.supabase.co/rest/v1/rpc/setter_apply';
  var KEY = 'sb_publishable_r9OWeA-XSdFMLKygoJM1Bg_Vr8D9aeZ';
  var f = document.getElementById('f'), msg = document.getElementById('msg'), go = document.getElementById('go');
  function say(t, c) { msg.textContent = t; msg.style.color = c; }
  f.addEventListener('submit', function (e) {
    e.preventDefault();
    var name = document.getElementById('name').value.trim(), contact = document.getElementById('contact').value.trim();
    if (name.length < 2 || contact.length < 5) { say('Please enter your name and a phone number or email.', 'var(--err)'); return; }
    go.disabled = true; say('Sending...', 'var(--mut)');
    fetch(URL_, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: KEY, Authorization: 'Bearer ' + KEY },
      body: JSON.stringify({ p_name: name, p_contact: contact, p_niche: document.getElementById('niche').value,
        p_note: document.getElementById('note').value, p_hp: document.getElementById('web').value })
    }).then(function (r) { return r.json(); }).then(function (j) {
      if (j && j.ok) { f.reset(); say('Thanks. We got your application and will be in touch if there is a fit.', 'var(--ok)'); }
      else { go.disabled = false; say((j && j.error) || 'Something went wrong. Please try again.', 'var(--err)'); }
    }).catch(function () { go.disabled = false; say('Could not send. Check your connection and try again.', 'var(--err)'); });
  });
})();
