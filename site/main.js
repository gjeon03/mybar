// Language switch (Korean in the page, English here) and the latest release's
// disk image for the download buttons.

const REPO = 'gjeon03/mybar';

const EN = {
  'nav.features': 'Features',
  'nav.how': 'How it works',
  'nav.install': 'Install',
  'nav.download': 'Download',
  'hero.eyebrow': 'menu bar organizer for macOS',
  'hero.title': 'Your menu bar,<br /><span class="accent">only what matters.</span>',
  'hero.sub': 'Hide the items you rarely use and bring them back with one click.<br />They open right where they belong, then tuck themselves away again.',
  'hero.download': 'Download for macOS',
  'hero.source': 'View source',
  'hero.c1': 'Free · open source',
  'hero.c2': 'Group icons',
  'hero.c3': 'Wi‑Fi and other system items',
  'mock.file': 'File',
  'mock.clock': '10:24 AM',
  'hero.cap1': 'A crowded menu bar',
  'hero.cap2': 'Tidied up by MyBar',
  'hero.cap3': 'Click the icon to reach the rest',
  'why.kicker': 'Why MyBar',
  'why.title': 'Keep your icons. Lose the clutter.',
  'why.sub': 'Every app you install seems to add another menu bar icon, and on a MacBook with a notch the extra ones can vanish behind it.<br />MyBar keeps <strong>only what you need right now</strong> in the menu bar and the rest one click away.',
  'why.before': 'Before',
  'why.after': 'After',
  'f1.v': 'Visible',
  'f1.h': 'Hidden',
  'f1.a': 'Always Hidden',
  'f1.title': 'Three sections',
  'f1.body': 'Drag items into <strong>Visible, Hidden or Always Hidden</strong> on the Layout tab. That’s all.',
  'f2.title': 'The Bar',
  'f2.body': 'Click MyBar’s icon and hidden items appear below the menu bar. Click one and it opens <strong>in its usual place</strong>, then hides again when you’re done.',
  'f3.title': 'Groups',
  'f3.body': 'Give related items <strong>their own menu bar icon</strong> that shows just that group.',
  'f4.sound': 'Sound',
  'f4.battery': 'Battery',
  'f4.title': 'System items too',
  'f4.body': 'On macOS 27, Apple’s own items such as Wi‑Fi, Sound and Battery hide just like apps — and come back when MyBar quits.',
  'f5.title': 'Your icon, your way',
  'f5.body': '12 built-in looks, any <strong>SF Symbol</strong>, or a picture of your own for MyBar’s icon.',
  'f6.title': 'One shortcut',
  'f6.body': '<strong>⌥⌘B</strong> shows and hides your hidden items. MyBar can also start when you log in.',
  'how.kicker': 'How it works',
  'how.title': 'Built for the new macOS 27 menu bar.',
  'how.sub': 'macOS 27 draws the whole menu bar in a new system process. MyBar uses the menu bar’s <strong>allow list</strong> to leave hidden apps out, allowing one back only while you use it.',
  'how.s1t': 'Hide',
  'how.s1': 'Every app except the hidden ones is allowed in the menu bar. No gaps, no folded «.',
  'how.s2t': 'Reveal',
  'how.s2': 'The app you click in the Bar is allowed for a moment; its item appears in place and MyBar presses it for you.',
  'how.s3t': 'Put back',
  'how.s3': 'A few seconds after the menu closes, it hides again. When MyBar quits, every item comes back.',
  'how.note': 'On macOS 26, MyBar uses long dividers that push items off screen. The <a href="https://github.com/gjeon03/mybar/tree/main/docs">developer docs</a> have the details.',
  'install.kicker': 'Install',
  'install.title': 'Done in a minute.',
  'install.s1t': 'Download',
  'install.s1': 'Open the disk image, drag MyBar into <strong>Applications</strong> and open it from there.',
  'install.s2t': 'Two permissions',
  'install.s2': 'In System Settings › Privacy & Security, turn on <strong>Accessibility</strong> and <strong>Screen & System Audio Recording</strong>.',
  'install.s3t': 'Tidy up',
  'install.s3': 'Drag the items you want to hide into Hidden on the Layout tab.',
  'install.all': 'All versions',
  'install.tip': 'Turned a permission on but MyBar still shows it in red? Click <strong>Reset Permissions…</strong> in Settings › Permissions and allow it again.',
  'faq.title': 'Questions',
  'faq.q1': 'Is it really free?',
  'faq.a1': 'Yes. It’s open source under the MIT license, with no ads or paid features.',
  'faq.q2': 'Why does it need Screen Recording?',
  'faq.a2': 'To show hidden items in the Bar, MyBar needs pictures of their menu bar icons. It only looks at the menu bar and sends nothing anywhere — all the code is on GitHub.',
  'faq.q3': 'Why isn’t it on the App Store?',
  'faq.a3': 'App Store apps run in a sandbox that can’t manage other apps’ menu bar items. MyBar ships as a disk image notarized by Apple instead.',
  'faq.q4': 'It stopped working after a macOS update.',
  'faq.a4': 'Some of the macOS 27 menu bar features MyBar uses aren’t public and can change in an update. Please open an <a href="https://github.com/gjeon03/mybar/issues">issue</a> with the report from Settings › Permissions › Copy Diagnostics.',
  'faq.q5': 'What happens to hidden items if I remove MyBar?',
  'faq.a5': 'They all come back the moment MyBar quits. Then move it to the Trash.',
  'faq.q6': 'Can I hide one app’s items separately?',
  'faq.a6': 'On macOS 27, hiding works app by app, because that’s how the menu bar decides what to show.',
  'footer.text': 'MIT License · <a href="https://github.com/gjeon03/mybar">GitHub</a> · made by <a href="https://gimbap.dev">gimbap.dev</a>',
};

const originals = new Map();
let release = null;

function storedLanguage() {
  try { return localStorage.getItem('mybar-lang'); } catch { return null; }
}

function setLanguage(lang) {
  const english = lang === 'en';
  document.documentElement.lang = english ? 'en' : 'ko';
  document.querySelectorAll('[data-i18n], [data-i18n-html]').forEach((node) => {
    const html = node.hasAttribute('data-i18n-html');
    const key = node.getAttribute(html ? 'data-i18n-html' : 'data-i18n');
    if (!originals.has(node)) originals.set(node, node.innerHTML);
    const text = english ? EN[key] : null;
    if (text == null) {
      node.innerHTML = originals.get(node);
    } else if (html) {
      node.innerHTML = text;
    } else {
      node.textContent = text;
    }
  });
  document.querySelectorAll('[data-lang-toggle]').forEach((button) => {
    button.textContent = english ? 'KO' : 'EN';
  });
  document.title = english ? 'MyBar — your menu bar, only what matters' : 'MyBar — 메뉴바는, 필요한 것만';
  showRelease();
  try { localStorage.setItem('mybar-lang', lang); } catch { /* private mode */ }
}

function showRelease() {
  if (!release) return;
  document.querySelectorAll('[data-download]').forEach((link) => { link.href = release.url; });
  document.querySelectorAll('[data-version-label]').forEach((label) => {
    label.textContent = `v${release.version} · macOS 27 · 26`;
  });
}

async function loadRelease() {
  try {
    const response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`);
    if (!response.ok) return;
    const data = await response.json();
    const dmg = (data.assets || []).find((asset) => asset.name.endsWith('.dmg'));
    if (!dmg) return;
    release = { url: dmg.browser_download_url, version: data.tag_name.replace(/^v/, '') };
    showRelease();
  } catch {
    // Offline or rate-limited: the buttons keep pointing at the releases page.
  }
}

const preferred = storedLanguage()
  ?? (new URLSearchParams(location.search).get('lang'))
  ?? (navigator.language.toLowerCase().startsWith('ko') ? 'ko' : 'en');
setLanguage(preferred === 'en' ? 'en' : 'ko');

document.querySelectorAll('[data-lang-toggle]').forEach((button) => {
  button.addEventListener('click', () => {
    setLanguage(document.documentElement.lang === 'en' ? 'ko' : 'en');
  });
});

loadRelease();
