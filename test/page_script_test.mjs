// Run with: node --test test/page_script_test.mjs
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { test } from 'node:test';
import assert from 'node:assert/strict';

const dart = readFileSync(new URL('../lib/services/web_video.dart', import.meta.url), 'utf8');
const script = dart.split("const String kPageScript = r'''")[1].split("''';")[0];

function page() {
  const videos = [video('https://cdn.test/a.mp4'), video('https://cdn.test/b.mp4')];
  const reports = [], intervals = [], timeouts = [];
  const window = {
    flutter_inappwebview: { callHandler: (_, report) => reports.push(report) },
    addEventListener() {},
    VTTCue: class {
      constructor(s, e, text) { this.startTime = s; this.endTime = e; this.text = text; }
    },
  };
  const listeners = {};
  const document = {
    querySelectorAll: (selector) => selector === 'video' ? videos : [],
    getElementsByTagName: () => videos,
    addEventListener(type, fn) { listeners[type] = fn; },
  };
  class XHR { open() {} }
  runInNewContext(script, {
    window, document, XMLHttpRequest: XHR, URL,
    location: { href: 'https://page.test/watch' },
    navigator: { userAgent: 'test' }, innerHeight: 800, innerWidth: 1200,
    setInterval: (fn) => intervals.push(fn), setTimeout: (fn) => timeouts.push(fn),
  });
  const report = () => { reports.length = 0; intervals[0](); return reports; };
  return { videos, window, listeners, report, draw: () => timeouts.shift()() };
}

function video(src) {
  const tracks = [];
  return {
    currentSrc: src, src, currentTime: 2, paused: false, duration: 100,
    muted: false, webkitDisplayingFullscreen: true, tracks,
    getBoundingClientRect: () => ({ left: 0, right: 640, top: 0, bottom: 360, width: 640, height: 360 }),
    hasAttribute: () => true, setAttribute() {}, addEventListener() {},
    addTextTrack() {
      const track = { cues: [], mode: '', addCue(c) { this.cues.push(c); },
        removeCue(c) { this.cues.splice(this.cues.indexOf(c), 1); } };
      tracks.push(track); return track;
    },
  };
}

test('every video is reported; subtitles target one exact element and source', () => {
  const p = page();
  const [a, b] = p.report();
  assert.notEqual(a.element, b.element);
  p.window.__vsubSend({ __vsub: 'cues', target: a.src, element: a.element,
    list: [[1, 3, 'Subtitle A', 'Original A']] });
  assert.equal(p.videos[0].tracks[0].cues[0].text, 'Subtitle A');
  assert.equal(p.videos[1].tracks.length, 0);
  assert.deepEqual(p.report().map(r => r.n), [1, 0]);
  p.window.__vsubSend({ __vsub: 'cues', target: b.src, element: b.element,
    list: [[1, 3, 'Subtitle B', 'Original B']] });
  assert.equal(p.videos[0].tracks[0].cues.length, 0);
  assert.equal(p.videos[0].tracks[0].mode, 'disabled');
  assert.equal(p.videos[1].tracks[0].cues[0].text, 'Subtitle B');
  assert.deepEqual(p.report().map(r => r.n), [0, 1]);
});

test('changing the source of an existing video hides and clears its old track', () => {
  const p = page();
  const [a] = p.report();
  p.window.__vsubSend({ __vsub: 'cues', target: a.src, element: a.element,
    list: [[1, 3, 'Subtitle A', 'Original A']] });
  p.videos[0].currentSrc = 'https://cdn.test/episode2.mp4';
  p.draw();
  assert.equal(p.videos[0].tracks[0].cues.length, 0);
  assert.equal(p.report()[0].n, 0);
  p.window.__vsubSend({ __vsub: 'cue', target: a.src, element: a.element,
    c: [3, 4, 'Late subtitle A', 'Original'] });
  assert.equal(p.videos[0].tracks[0].cues.length, 0);
});

test('a long press finds the link around a thumbnail inside other boxes', () => {
  const p = page();
  const a = { nodeType: 1, tagName: 'A', href: 'https://page.test/film/7',
    innerText: '  Film   seven ', querySelector: () => null };
  const box = { nodeType: 1, tagName: 'DIV', parentElement: a };
  const img = { nodeType: 1, tagName: 'IMG', src: 'https://img.test/7.jpg', parentElement: box };
  p.listeners.touchstart({ target: img });
  const got = JSON.parse(p.window.__vsubPressed());
  assert.equal(got.href, 'https://page.test/film/7');
  assert.equal(got.img, 'https://img.test/7.jpg');
  assert.equal(got.text, 'Film   seven');
  p.listeners.touchstart({ target: { nodeType: 1, tagName: 'P', parentElement: null } });
  assert.equal(JSON.parse(p.window.__vsubPressed()).href, '');
});
