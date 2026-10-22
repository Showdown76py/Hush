'use strict';

const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const smooth = (u) => u * u * (3 - 2 * u);

const FR = {
  skip: 'Aller au contenu',
  'nav.listen': 'Écouter',
  'nav.how': 'Fonctionnement',
  'nav.setup': 'Installation',
  'nav.faq': 'FAQ',
  'nav.download': 'Télécharger',
  'hero.eyebrow': 'Hush pour Mac',
  'hero.title1': 'Votre voix.',
  'hero.title2': 'Pas votre musique.',
  'hero.lede': 'Un micro propre pour Discord, Zoom, Meet et OBS. Hush fait passer votre voix par le filtre d’Apple : on vous entend, vous, et pas ce que joue votre Mac.',
  'hero.download': 'Télécharger pour Mac',
  'hero.listen': 'Écouter la différence',
  'hero.meta': 'Gratuit et open source · macOS 14 ou plus récent',
  'hero.alt': 'Le menu Hush ouvert dans la barre de menus de macOS, avec ses indicateurs micro et envoi aux apps',
  'scene.title': 'Comment Hush nettoie votre micro',
  'scene.s1': '<strong>Quand votre Mac joue de la musique,</strong> le micro capte le son de vos haut-parleurs.',
  'scene.s2': '<strong>Puis vous parlez.</strong> Le micro ne fait pas la différence entre votre voix et la chanson.',
  'scene.s3': '<strong>Sans Hush,</strong> votre auditoire entend tout. Votre playlist, la vidéo, le jeu.',
  'scene.s4': '<strong>Hush s’active.</strong> Le traitement de la voix d’Apple retire tout ce que joue votre Mac.',
  'scene.s5': '<strong>Seule votre voix passe.</strong> Environ 43 dB de musique en moins.',
  'scene.music': 'La musique des haut-parleurs',
  'scene.voice': 'Votre voix',
  'scene.out': 'Ce qu’entend votre auditoire',
  'listen.eyebrow': 'Écouter',
  'listen.title': 'Basculez l’interrupteur. La musique disparaît.',
  'listen.sub': 'Lancez la lecture, puis activez et désactivez Hush pendant qu’elle tourne.',
  'listen.label': 'Ce qu’entend votre auditoire',
  'listen.lvoice': 'Voix',
  'listen.lmusic': 'Musique',
  'listen.off': 'Désactivé : ils entendent aussi votre musique (aucun filtrage)',
  'listen.on': 'Activé : ils n’entendent que vous (filtrage actif)',
  'listen.note': 'Simulation fondée sur les mesures de la vraie app.',
  'listen.credit': 'Musique\u00a0: «\u00a0Be Chillin\u00a0» d’Alexander Nakarada',
  'how.eyebrow': 'Fonctionnement',
  'how.title': 'Un travail discret, dans votre barre de menus.',
  'how.menu.t': 'Dans votre barre de menus.',
  'how.menu.p': 'Deux indicateurs montrent ce qu’entend votre micro et ce que reçoivent les apps. Lancez un son : le premier bouge, le second reste calme.',
  'how.menu.p2': 'Dès que vous parlez, vous voyez votre voix partir vers les apps.',
  'how.apple.mic': 'Micro',
  'how.apple.sent': 'Envoyé aux apps',
  'how.apple.t': 'Le traitement de FaceTime.',
  'how.apple.p': 'Le même traitement Apple qui garde les appels FaceTime propres retire tout le son de votre Mac du micro.',
  'how.apps.t': 'Compatible avec toutes les apps.',
  'how.apps.p': 'Hush ajoute un micro virtuel appelé « Hush Microphone ». Choisissez-le dans n’importe quelle app qui permet de choisir une entrée.',
  'how.auto.idle': 'En veille',
  'how.auto.live': 'En appel',
  'how.auto.t': 'Actif seulement quand vous parlez à quelqu’un.',
  'how.auto.p': 'En mode automatique, Hush ne tourne que si une app écoute Hush Microphone : le reste du temps, vos haut-parleurs sonnent normalement et votre vie privée est mieux protégée.',
  'how.level.before': 'Votre micro',
  'how.level.after': 'Envoyé',
  'how.level.t': 'Votre voix reste régulière.',
  'how.level.p': 'Hush ajuste votre niveau seulement quand vous parlez : voix faible ou forte, le résultat est le même, et le bruit de fond n’est jamais remonté.',
  'stats.removed': 'de musique des haut-parleurs retirée du micro',
  'stats.delay': 'de délai au total, imperceptible en conversation',
  'stats.rec': 'enregistrement. Le son est traité en temps réel, sur votre Mac.',
  'stats.note': 'Tous les détails des mesures sont <a href="https://github.com/Showdown76py/Hush/blob/main/Prototypes/MEASUREMENTS.md">sur GitHub</a>.',
  'setup.eyebrow': 'Installation',
  'setup.title': 'Prêt en une minute environ.',
  'setup.sub': 'Glissez Hush dans Applications et ouvrez-le. Suivez les étapes, et c’est prêt !',
  'setup.1.t': 'Ouvrez Hush',
  'setup.1.p': 'Retrouvez les réglages de Hush à tout moment dans la barre de menus.',
  'setup.2.t': 'Autorisez le micro',
  'setup.2.p': 'Rien n’est enregistré ni envoyé nulle part. Tout est traité sur votre Mac.',
  'setup.3.t': 'Ajoutez Hush Microphone',
  'setup.3.p': 'macOS demande votre mot de passe une seule fois, pour installer le micro virtuel.',
  'setup.4.t': 'Écoutez la différence',
  'setup.4.p': 'Un test avant/après de 10 secondes, avec votre propre voix.',
  'setup.5.t': 'Choisissez-le dans votre app',
  'setup.5.p': 'Sélectionnez Hush Microphone comme entrée dans Discord, Zoom, Meet ou OBS.',
  'faq.title': 'Questions.',
  'faq.open.q': 'macOS refuse d’ouvrir Hush.',
  'faq.open.a': 'Hush n’est pas encore notarisé par Apple, donc macOS affiche un avertissement au premier lancement. Pour l’ouvrir :',
  'faq.open.l1': '<strong>macOS 15 ou plus récent :</strong> essayez d’ouvrir Hush une fois, puis allez dans Réglages Système › Confidentialité et sécurité et cliquez sur Ouvrir quand même.',
  'faq.open.l2': '<strong>macOS 14 :</strong> Contrôle-clic sur Hush dans Applications, choisissez Ouvrir, puis Ouvrir à nouveau.',
  'faq.open.l3': '<strong>Depuis le Terminal :</strong>',
  'faq.rec.q': 'Hush m’enregistre-t-il ?',
  'faq.rec.a': 'Non. Le son est traité en direct, en mémoire. Le seul enregistrement est le test avant/après des écrans d’accueil, gardé dans un fichier temporaire local.',
  'faq.delay.q': 'Y a-t-il un délai ?',
  'faq.delay.a': 'Environ 80 ms au total : le traitement d’Apple ajoute environ 65 ms, Hush environ 15 ms. Vos interlocuteurs ne le remarquent pas en conversation.',
  'faq.duck.q': 'Pourquoi ma musique baisse-t-elle un peu ?',
  'faq.duck.a': 'macOS baisse les autres sons dès que le traitement de la voix tourne. Hush demande la plus petite baisse permise par Apple, environ 8 dB au lieu de 30 dB par défaut. En mode automatique, ça n’arrive que pendant les appels.',
  'faq.phones.q': 'Casque, AirPods ?',
  'faq.phones.a': 'Ça marche. Hush suit tout seul les changements de sortie audio.',
  'faq.uninstall.q': 'Comment le désinstaller ?',
  'faq.uninstall.a': 'Dans Hush, ouvrez les Réglages et cliquez sur Désinstaller le micro virtuel, puis mettez Hush à la corbeille.',
  'final.title': 'Parlez librement. Gardez la musique.',
  'final.source': 'Voir le code source',
  'footer.by': 'créé par',
  'footer.license': 'Licence MIT',
  'footer.releases': 'Versions',
};

const META = {
  en: {
    title: 'Hush: a clean microphone for your Mac',
    desc: document.querySelector('meta[name="description"]').content,
    langBtn: ['FR', 'Passer en français'],
    play: 'Play', pause: 'Pause', prev: 'Previous step', next: 'Next step',
    version: (v) => `Version ${v}`,
  },
  fr: {
    title: 'Hush : un micro propre pour votre Mac',
    desc: 'Hush retire du micro la musique et les vidéos que joue votre Mac, grâce au traitement de la voix de FaceTime. Compatible avec Discord, Zoom, Meet et OBS. Gratuit et open source.',
    langBtn: ['EN', 'Switch to English'],
    play: 'Lecture', pause: 'Pause', prev: 'Étape précédente', next: 'Étape suivante',
    version: (v) => `Version ${v}`,
  },
};

let lang = 'en';
let latestVersion = '';
const langListeners = [];

function pickLang() {
  const q = new URLSearchParams(location.search).get('lang');
  if (q === 'en' || q === 'fr') return q;
  try {
    const saved = localStorage.getItem('hush.lang');
    if (saved === 'en' || saved === 'fr') return saved;
  } catch {}
  return (navigator.languages || [navigator.language]).some((l) => /^fr\b/i.test(l)) ? 'fr' : 'en';
}

function applyLang(next) {
  lang = next;
  document.documentElement.lang = next;
  for (const el of document.querySelectorAll('[data-i18n]')) {
    el.dataset.en ??= el.textContent;
    el.textContent = next === 'fr' ? FR[el.dataset.i18n] ?? el.dataset.en : el.dataset.en;
  }
  for (const el of document.querySelectorAll('[data-i18n-alt]')) {
    el.dataset.enAlt ??= el.alt;
    el.alt = next === 'fr' ? FR[el.dataset.i18nAlt] ?? el.dataset.enAlt : el.dataset.enAlt;
  }
  for (const el of document.querySelectorAll('[data-i18n-html]')) {
    el.dataset.en ??= el.innerHTML;
    el.innerHTML = next === 'fr' ? FR[el.dataset.i18nHtml] ?? el.dataset.en : el.dataset.en;
  }
  const m = META[next];
  document.title = m.title;
  document.querySelector('meta[name="description"]').content = m.desc;
  const btn = document.getElementById('lang');
  btn.textContent = m.langBtn[0];
  btn.setAttribute('aria-label', m.langBtn[1]);
  document.getElementById('railPrev').setAttribute('aria-label', m.prev);
  document.getElementById('railNext').setAttribute('aria-label', m.next);
  renderVersion();
  langListeners.forEach((fn) => fn(next));
}

function renderVersion() {
  for (const el of document.querySelectorAll('.js-version')) {
    el.textContent = latestVersion ? META[lang].version(latestVersion) : '';
  }
}

document.getElementById('lang').addEventListener('click', () => {
  const next = lang === 'en' ? 'fr' : 'en';
  try { localStorage.setItem('hush.lang', next); } catch {}
  applyLang(next);
});

async function resolveDownload() {
  try {
    const r = await fetch('https://api.github.com/repos/Showdown76py/Hush/releases/latest', {
      headers: { Accept: 'application/vnd.github+json' },
    });
    if (!r.ok) return;
    const rel = await r.json();
    const dmg = (rel.assets || []).find((a) => a.name.endsWith('.dmg'));
    if (!dmg) return;
    for (const a of document.querySelectorAll('.js-download')) a.href = dmg.browser_download_url;
    latestVersion = rel.tag_name.replace(/^v/, '');
    renderVersion();
  } catch {}
}

function intro() {
  document.querySelectorAll('[data-intro]').forEach((el, i) => el.style.setProperty('--i', i));
  const menu = document.getElementById('menu');
  const mb = document.getElementById('mbHush');
  const setMenu = (open) => menu.classList.toggle('is-closed', !open);
  setMenu(false);
  mb.addEventListener('pointerdown', () => setMenu(menu.classList.contains('is-closed')));
  requestAnimationFrame(() => requestAnimationFrame(() => {
    document.documentElement.classList.add('is-loaded');
    setTimeout(() => setMenu(true), reduceMotion.matches ? 0 : 1100);
  }));
}

function reveal() {
  const els = document.querySelectorAll('[data-reveal]');
  for (const el of els) {
    const sibs = [...el.parentElement.children].filter((c) => c.hasAttribute('data-reveal'));
    el.style.setProperty('--i', Math.min(sibs.indexOf(el), 5));
  }
  if (!('IntersectionObserver' in window)) return els.forEach((el) => el.classList.add('is-in'));
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (e.isIntersecting) {
        e.target.classList.add('is-in');
        io.unobserve(e.target);
      }
    }
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.12 });
  els.forEach((el) => io.observe(el));
}

function navBorder() {
  const nav = document.getElementById('nav');
  const scene = document.getElementById('scene');
  const update = () => {
    nav.classList.toggle('is-scrolled', scrollY > 8);
    const r = scene.getBoundingClientRect(), mid = nav.offsetHeight / 2;
    nav.classList.toggle('is-dark', r.top <= mid && r.bottom >= mid);
  };
  addEventListener('scroll', update, { passive: true });
  update();
}

function scene() {
  const section = document.getElementById('scene');
  const stage = section.querySelector('.scene-stage');
  const canvas = section.querySelector('.scene-canvas');
  const ctx = canvas.getContext('2d');
  const steps = [...section.querySelectorAll('.step')];
  const node = section.querySelector('.node');
  const tags = {
    music: section.querySelector('.tag-music'),
    voice: section.querySelector('.tag-voice'),
    out: section.querySelector('.tag-out'),
  };
  const cuts = [-0.12, 0.17, 0.36, 0.56, 0.76];
  const css = getComputedStyle(section);
  const colors = { music: css.getPropertyValue('--music').trim(), voice: css.getPropertyValue('--voice').trim() };

  let W = 0, H = 0, L = null, visible = false, t = 0, last = 0, raf = 0;

  function layout() {
    const r = stage.getBoundingClientRect();
    const dpr = Math.min(devicePixelRatio || 1, 2);
    W = r.width; H = r.height;
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const narrow = W < 640;
    L = {
      src: W * (narrow ? 0.05 : 0.07),
      mx: W * 0.5,
      my: H * 0.5,
      musicY: H * 0.16,
      voiceY: H * 0.84,
      end: W * (narrow ? 0.95 : 0.93),
      r: 40,
      amp: clamp(H * 0.055, 9, 34),
    };
    node.style.left = `${L.mx}px`;
    node.style.top = `${L.my}px`;
    place(tags.music, L.src, L.musicY - 30);
    place(tags.voice, L.src, L.voiceY + 32);
    place(tags.out, L.end, L.my - L.amp - 34);
  }

  function place(el, x, y) {
    el.style.left = `${x}px`;
    el.style.top = `${y}px`;
  }

  const music = (x, t) => {
    const ph = x * 0.045 - t * 3.4;
    const beat = 0.55 + 0.45 * Math.pow(0.5 + 0.5 * Math.sin(x * 0.011 - t * 2.4), 3);
    return (0.55 * Math.sin(ph) + 0.3 * Math.sin(ph * 2.3 + 1.3) + 0.15 * Math.sin(ph * 5.1 + 0.4)) * beat;
  };
  const voice = (x, t) => {
    const syll = Math.pow(Math.max(0, Math.sin(x * 0.021 - t * 2.1)), 1.4) * (0.65 + 0.35 * Math.sin(x * 0.006 - t * 0.8));
    return (0.65 * Math.sin(x * 0.075 - t * 6) + 0.35 * Math.sin(x * 0.14 - t * 8.5)) * syll;
  };

  function stroke(pts, color, alpha) {
    if (pts.length < 4 || alpha <= 0.01) return;
    ctx.beginPath();
    ctx.moveTo(pts[0], pts[1]);
    for (let i = 2; i < pts.length; i += 2) ctx.lineTo(pts[i], pts[i + 1]);
    ctx.strokeStyle = color;
    ctx.globalAlpha = alpha * 0.22;
    ctx.lineWidth = 7;
    ctx.stroke();
    ctx.globalAlpha = alpha;
    ctx.lineWidth = 2.2;
    ctx.stroke();
  }

  function lane(y0, fn, amp, reveal) {
    const x1 = L.mx - L.r;
    const len = x1 - L.src;
    const front = L.src + len * reveal;
    const pts = [];
    for (let x = L.src; x <= front; x += 3) {
      const u = (x - L.src) / len;
      const y = y0 + (L.my - y0) * smooth(u);
      const taper = Math.min(1, (front - x) / 50, u * 8) * (1 - 0.55 * smooth(clamp((u - 0.8) / 0.2)));
      pts.push(x, y + fn(x, t) * amp * taper);
    }
    return pts;
  }

  function out(fn, amp, reveal) {
    const x0 = L.mx + L.r;
    const front = x0 + (L.end - x0) * reveal;
    const pts = [];
    for (let x = x0; x <= front; x += 3) {
      const u = (x - x0) / (L.end - x0);
      const taper = Math.min(1, (front - x) / 50, u * 10 + 0.4) * (1 - smooth(clamp((u - 0.88) / 0.12)));
      pts.push(x, L.my + fn(x, t) * amp * taper);
    }
    return pts;
  }

  function progress() {
    const r = section.getBoundingClientRect();
    return -r.top / (r.height - innerHeight);
  }

  function draw() {
    const p = progress();
    const musicReveal = clamp((p + 0.12) / 0.2);
    const voiceReveal = clamp((p - 0.15) / 0.16);
    const outReveal = clamp((p - 0.36) / 0.14);
    const musicOut = 1 - smooth(clamp((p - 0.58) / 0.16));

    let active = 0;
    cuts.forEach((c, i) => { if (p >= c) active = i; });
    steps.forEach((s, i) => {
      s.classList.toggle('is-active', i === active);
      s.classList.toggle('is-past', i < active);
    });
    node.classList.toggle('is-on', p >= 0.56);
    tags.music.classList.toggle('is-on', musicReveal > 0.25);
    tags.voice.classList.toggle('is-on', voiceReveal > 0.25);
    tags.out.classList.toggle('is-on', outReveal > 0.4);

    ctx.clearRect(0, 0, W, H);
    ctx.globalCompositeOperation = 'lighter';
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    stroke(lane(L.musicY, music, L.amp, musicReveal), colors.music, 1);
    stroke(lane(L.voiceY, voice, L.amp * 1.1, voiceReveal), colors.voice, 1);
    stroke(out(music, L.amp * musicOut, outReveal), colors.music, musicOut);
    stroke(out(voice, L.amp * 1.1, outReveal), colors.voice, 1);
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = 'source-over';
  }

  function frame(now) {
    if (!reduceMotion.matches) t += Math.min(0.05, (now - last) / 1000);
    last = now;
    draw();
    raf = visible ? requestAnimationFrame(frame) : 0;
  }

  function start() {
    if (raf) return;
    last = performance.now();
    raf = requestAnimationFrame(frame);
  }

  new IntersectionObserver(([e]) => {
    visible = e.isIntersecting;
    if (visible) start();
  }).observe(section);
  new ResizeObserver(() => { layout(); draw(); }).observe(stage);
  addEventListener('scroll', () => { if (visible && !raf) draw(); }, { passive: true });
  layout();
  draw();
}

function player() {
  const root = document.querySelector('.player');
  const playBtn = document.getElementById('play');
  const sw = document.getElementById('hushSwitch');
  const canvas = root.querySelector('.player-wave');
  const c2d = canvas.getContext('2d');
  const BAR = 4, GAP = 3;

  let ac = null, nodes = null, source = null, clip = null;
  let playing = false, hush = false, mix = 0;
  let history = [], raf = 0, lastPush = 0, startedAt = 0, offset = 0;
  const clips = {};

  function colors() {
    const s = getComputedStyle(root);
    return { music: s.getPropertyValue('--music').trim(), voice: s.getPropertyValue('--voice').trim(), idle: s.getPropertyValue('--line').trim() };
  }
  let col = colors();
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { col = colors(); drawWave(); });

  function size() {
    const dpr = Math.min(devicePixelRatio || 1, 2);
    const r = canvas.getBoundingClientRect();
    canvas.width = Math.round(r.width * dpr);
    canvas.height = Math.round(r.height * dpr);
    c2d.setTransform(dpr, 0, 0, dpr, 0, 0);
    const n = Math.floor(r.width / (BAR + GAP));
    history = history.slice(-n);
    while (history.length < n) history.unshift([0, 0]);
    drawWave();
  }

  const raw = {};
  function fetchClip(l) {
    raw[l] ??= Promise.all([
      fetch(`assets/audio/demo-${l}.m4a`).then((r) => r.arrayBuffer()),
      fetch(`assets/audio/demo-${l}.json`).then((r) => r.json()),
    ]).catch((err) => {
      delete raw[l];
      throw err;
    });
    return raw[l];
  }

  async function load(l) {
    if (!clips[l]) {
      const [audio, env] = await fetchClip(l);
      clips[l] = { buf: await ac.decodeAudioData(audio.slice(0)), env };
    }
    return clips[l];
  }

  function graph() {
    const split = ac.createChannelSplitter(2);
    const off = ac.createGain();
    const on = ac.createGain();
    off.gain.value = hush ? 0 : 1;
    on.gain.value = hush ? 1 : 0;
    split.connect(off, 0);
    split.connect(on, 1);
    off.connect(ac.destination);
    on.connect(ac.destination);
    return { split, off, on };
  }

  async function startSource(at) {
    clip = await load(lang);
    const loop = clip.env.loop;
    if (source) source.stop();
    source = ac.createBufferSource();
    source.buffer = clip.buf;
    source.loop = true;
    source.loopStart = 0;
    source.loopEnd = loop;
    source.connect(nodes.split);
    source.start(0, at % loop);
    startedAt = ac.currentTime - (at % loop);
  }

  async function play() {
    playBtn.classList.add('is-loading');
    try {
      if (navigator.audioSession) navigator.audioSession.type = 'playback';
      if (!ac) {
        ac = new (window.AudioContext || window.webkitAudioContext)();
        nodes = graph();
      }
      const resumed = ac.state === 'running' ? null : ac.resume();
      const unlock = ac.createBufferSource();
      unlock.buffer = ac.createBuffer(1, 1, ac.sampleRate);
      unlock.connect(ac.destination);
      unlock.start(0);
      await resumed;
      if (!source) await startSource(offset);
      playing = true;
      setPlayUI();
      loop();
    } catch (err) {
      console.error(err);
    } finally {
      playBtn.classList.remove('is-loading');
    }
  }

  async function pause() {
    playing = false;
    setPlayUI();
    if (ac) await ac.suspend();
  }

  function setPlayUI() {
    playBtn.classList.toggle('is-playing', playing);
    playBtn.setAttribute('aria-label', playing ? META[lang].pause : META[lang].play);
  }

  function setHush(on) {
    hush = on;
    sw.setAttribute('aria-checked', String(on));
    root.classList.toggle('is-hush', on);
    if (!nodes) return;
    const t = ac.currentTime;
    nodes.off.gain.setTargetAtTime(on ? 0 : 1, t, 0.03);
    nodes.on.gain.setTargetAtTime(on ? 1 : 0, t, 0.03);
  }

  function loop(now = performance.now()) {
    if (!playing) { raf = 0; return; }
    if (now - lastPush > 50 && clip) {
      const { env } = clip;
      const i = Math.floor(((ac.currentTime - startedAt) % env.loop) / env.frame) % env.off.voice.length;
      mix += ((hush ? 1 : 0) - mix) * 0.6;
      const at = (k) => (env.off[k][i] + (env.on[k][i] - env.off[k][i]) * mix) / 1000;
      history.push([at('voice'), at('music')]);
      history.shift();
      lastPush = now;
      drawWave();
    }
    raf = requestAnimationFrame(loop);
  }

  function bar(x, y, h, color, alpha) {
    if (h < 0.5) return;
    c2d.globalAlpha = alpha;
    c2d.fillStyle = color;
    c2d.beginPath();
    if (c2d.roundRect) c2d.roundRect(x, y, BAR, h, BAR / 2);
    else c2d.rect(x, y, BAR, h);
    c2d.fill();
  }

  function drawWave() {
    const w = canvas.clientWidth, h = canvas.clientHeight, mid = h / 2;
    c2d.clearRect(0, 0, w, h);
    const scale = (v) => Math.min(mid - 3, Math.sqrt(v) * mid * 1.7);
    history.forEach(([v, m], i) => {
      const x = i * (BAR + GAP);
      const age = 0.35 + 0.65 * (i / history.length);
      if (v === 0 && m === 0) return bar(x, mid - 0.75, 1.5, col.idle, 1);
      const hv = Math.max(1.5, scale(v)), hm = Math.max(1.5, scale(m));
      bar(x, mid - 1 - hv, hv, col.voice, age);
      bar(x, mid + 1, hm, col.music, age);
    });
    c2d.globalAlpha = 1;
  }

  playBtn.addEventListener('click', () => (playing ? pause() : play()));
  sw.addEventListener('click', () => setHush(!hush));
  langListeners.push(async () => {
    setPlayUI();
    if (!ac || !source) return;
    offset = ac.currentTime - startedAt;
    if (playing) await startSource(offset);
    else { source.stop(); source = null; }
  });
  new ResizeObserver(size).observe(canvas);
  new IntersectionObserver(([e]) => {
    if (!e.isIntersecting && playing) pause();
  }).observe(root);
  const prefetch = new IntersectionObserver(([e]) => {
    if (!e.isIntersecting) return;
    fetchClip(lang).catch(() => {});
    prefetch.disconnect();
  }, { rootMargin: '800px 0px' });
  prefetch.observe(root);
}

function rail() {
  const el = document.getElementById('rail');
  const prev = document.getElementById('railPrev');
  const next = document.getElementById('railNext');
  const step = () => {
    const s = el.querySelector('.slide');
    return s.getBoundingClientRect().width + parseFloat(getComputedStyle(el).columnGap || 20);
  };
  const behavior = () => (reduceMotion.matches ? 'auto' : 'smooth');
  const update = () => {
    prev.disabled = el.scrollLeft < 4;
    next.disabled = el.scrollLeft + el.clientWidth > el.scrollWidth - 4;
  };
  prev.addEventListener('click', () => el.scrollBy({ left: -step(), behavior: behavior() }));
  next.addEventListener('click', () => el.scrollBy({ left: step(), behavior: behavior() }));
  el.addEventListener('scroll', update, { passive: true });
  addEventListener('resize', update);
  update();
}

applyLang(pickLang());
intro();
reveal();
navBorder();
scene();
player();
rail();
resolveDownload();
