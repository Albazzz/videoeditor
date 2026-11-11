import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Ad and tracking servers. A host matches when it equals an entry or is a
/// subdomain of one.
const kAdDomains = <String>[
  // Google
  'doubleclick.net', 'googlesyndication.com', 'googleadservices.com',
  'googletagservices.com', 'adservice.google.com', 'google-analytics.com',
  // Large exchanges and networks
  'adnxs.com', 'adsrvr.org', 'amazon-adsystem.com', 'criteo.com',
  'criteo.net', 'taboola.com', 'outbrain.com', 'pubmatic.com',
  'rubiconproject.com', 'openx.net', 'casalemedia.com', 'smartadserver.com',
  'adform.net', 'yieldmo.com', 'sharethrough.com', 'teads.tv', 'moatads.com',
  'scorecardresearch.com', 'quantserve.com', 'bidswitch.net', '3lift.com',
  'indexww.com', 'media.net', 'advertising.com', 'adcolony.com',
  'applovin.com', 'inmobi.com', 'mopub.com', 'zedo.com', 'revcontent.com',
  'mgid.com', 'adskeeper.com', 'adskeeper.co.uk', 'lijit.com',
  'sovrn.com', 'gumgum.com', 'contextweb.com', 'adroll.com',
  'serving-sys.com', 'adsafeprotected.com', 'doubleverify.com',
  'hotjar.com', 'yandexadexchange.net', 'adriver.ru',
  // Pop-up and pop-under networks common on streaming sites
  'propellerads.com', 'propeller-tracking.com', 'popads.net', 'popcash.net',
  'popmyads.com', 'popunder.net', 'adsterra.com', 'adsterratech.com',
  'highperformanceformat.com', 'profitablegatecpm.com',
  'effectiveratecpm.com', 'exoclick.com', 'exosrv.com', 'exdynsrv.com',
  'magsrv.com', 'realsrv.com', 'juicyads.com', 'trafficjunky.net',
  'trafficjunky.com', 'trafficstars.com', 'tsyndicate.com',
  'hilltopads.net', 'hilltopads.com', 'clickadu.com', 'clickaine.com',
  'adcash.com', 'ad-maven.com', 'admaven.com', 'onclickads.net',
  'onclkds.com', 'onclasrv.com', 'bidvertiser.com', 'galaksion.com',
  'monetag.com', 'a-ads.com', 'coinzillatag.com', 'adspyglass.com',
  'plugrush.com', 'ero-advertising.com', 'adxpansion.com', 'twinrdsrv.com',
  'richads.com', 'evadav.com', 'zeropark.com', 'adnium.com', 'yllix.com',
  'revenuehits.com', 'adf.ly', 'shorte.st', 'bebi.com',
  // Vietnamese networks
  'admicro.vn', 'eclick.vn', 'novanet.vn', 'blueseed.tv', 'ants.vn',
  'adtima.vn', 'yomedia.vn',
];

/// Page elements that only ever hold adverts.
const kAdSelectors = <String>[
  '.adsbygoogle',
  'ins.adsbygoogle',
  '[id^="google_ads_iframe"]',
  '[id^="div-gpt-ad"]',
  'iframe[src*="doubleclick.net"]',
  'iframe[src*="googlesyndication.com"]',
  '.ad-banner',
  '.ads-banner',
  '.banner-ads',
  '.popup-ads',
];

bool isAdHost(String host) {
  final h = host.toLowerCase();
  for (final d in kAdDomains) {
    if (h == d || h.endsWith('.$d')) return true;
  }
  return false;
}

const _secondLevel = {'com', 'co', 'net', 'org', 'gov', 'edu', 'ac'};

/// The registrable part of a host: `a.b.example.com` and `example.com.vn`
/// both keep just enough labels to name one site.
String siteOf(String host) {
  final parts = host.toLowerCase().split('.');
  if (parts.length <= 2) return parts.join('.');
  final threeLabels =
      parts.last.length == 2 && _secondLevel.contains(parts[parts.length - 2]);
  return parts.sublist(parts.length - (threeLabels ? 3 : 2)).join('.');
}

/// True when a new window from [page] to [target] should not open.
bool shouldBlockPopup(Uri? target, Uri? page) {
  if (target == null || !target.hasScheme) return true;
  if (!target.scheme.startsWith('http')) return false;
  if (isAdHost(target.host)) return true;
  // Pop-ups to another site are how streaming pages open adverts.
  return page != null && siteOf(target.host) != siteOf(page.host);
}

/// Pattern in the form WebKit's content blocker accepts (no alternation).
String adUrlFilter(String domain) =>
    '^[^:]+://+([^:/]+\\.)?${domain.replaceAll('.', r'\.')}[:/]';

/// Rules for the web view's built-in content blocker.
List<ContentBlocker> adBlockRules() => [
  for (final d in kAdDomains)
    ContentBlocker(
      trigger: ContentBlockerTrigger(urlFilter: adUrlFilter(d)),
      action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
    ),
  ContentBlocker(
    trigger: ContentBlockerTrigger(urlFilter: '.*'),
    action: ContentBlockerAction(
      type: ContentBlockerActionType.CSS_DISPLAY_NONE,
      selector: kAdSelectors.join(', '),
    ),
  ),
];

/// Injected into every frame while blocking is on. Stops scripts and
/// invisible links from opening other sites in a new window, and tells the
/// app what it stopped (handler `vsubPopup`).
const String kAdBlockScript = r'''
(function () {
  if (window.__vsubAd) return;
  window.__vsubAd = true;

  function site(h) {
    h = (h || '').toLowerCase().split('.');
    if (h.length <= 2) return h.join('.');
    var three = h[h.length - 1].length === 2 &&
        /^(com|co|net|org|gov|edu|ac)$/.test(h[h.length - 2]);
    return h.slice(three ? -3 : -2).join('.');
  }
  function otherSite(u) {
    try {
      var x = new URL(u, location.href);
      if (!/^https?:$/.test(x.protocol)) return false;
      return site(x.hostname) !== site(location.hostname);
    } catch (e) { return false; }
  }
  function report(u) {
    try {
      var x = u ? new URL(u, location.href).href : '';
      window.flutter_inappwebview.callHandler('vsubPopup', x);
    } catch (e) {}
  }

  var realOpen = window.open;
  window.open = function (u) {
    // An empty window that is filled in later is the classic pop-under.
    if (!u || u === 'about:blank' || otherSite(u)) {
      report(u);
      return null;
    }
    return realOpen.apply(window, arguments);
  };

  document.addEventListener('click', function (ev) {
    var a = ev.target && ev.target.closest ? ev.target.closest('a[target]') : null;
    if (!a) return;
    var t = (a.getAttribute('target') || '').toLowerCase();
    if (t === '' || t === '_self' || t === '_top' || t === '_parent') return;
    if (otherSite(a.href)) {
      ev.preventDefault();
      ev.stopPropagation();
      report(a.href);
    }
  }, true);
})();
''';
