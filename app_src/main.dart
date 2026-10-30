import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:math' as math;

const feedUrl = String.fromEnvironment('FEED_URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SignalApp());
}

double num0(dynamic v) => (v as num?)?.toDouble() ?? 0;

// Binance USDT-M perpetual futures: base coin -> contract symbol (filled from exchangeInfo, e.g. 'PEPE' -> '1000PEPEUSDT')
final Map<String, String> futSymbols = {};
const favorites = [
  'BTC', 'ETH', 'SOL', 'BNB', 'XRP', 'DOGE',
  'GOLD', 'SILVER', 'PLATINUM', 'PALLADIUM', 'COPPER', 'OIL', 'BRENT', 'NATGAS',
  'EURUSD', 'GBPUSD', 'USDJPY', 'AUDUSD', 'NZDUSD', 'USDCAD', 'USDCHF',
];
const yahooPairs = {
  // Precious metals and energy
  'GOLD': 'GC=F', 'SILVER': 'SI=F', 'PLATINUM': 'PL=F', 'PALLADIUM': 'PA=F',
  'COPPER': 'HG=F', 'OIL': 'CL=F', 'BRENT': 'BZ=F', 'NATGAS': 'NG=F',
  // Agricultural commodities
  'CORN': 'ZC=F', 'WHEAT': 'ZW=F', 'SOYBEANS': 'ZS=F',
  'COFFEE': 'KC=F', 'SUGAR': 'SB=F', 'COTTON': 'CT=F',
  // Forex majors
  'EURUSD': 'EURUSD=X', 'GBPUSD': 'GBPUSD=X', 'USDJPY': 'USDJPY=X',
  'AUDUSD': 'AUDUSD=X', 'NZDUSD': 'NZDUSD=X', 'USDCAD': 'USDCAD=X', 'USDCHF': 'USDCHF=X',
  // Common forex crosses
  'EURGBP': 'EURGBP=X', 'EURJPY': 'EURJPY=X', 'EURCHF': 'EURCHF=X',
  'EURCAD': 'EURCAD=X', 'EURAUD': 'EURAUD=X', 'EURNZD': 'EURNZD=X',
  'GBPJPY': 'GBPJPY=X', 'GBPCHF': 'GBPCHF=X', 'GBPCAD': 'GBPCAD=X',
  'GBPAUD': 'GBPAUD=X', 'GBPNZD': 'GBPNZD=X',
  'AUDJPY': 'AUDJPY=X', 'AUDCAD': 'AUDCAD=X', 'AUDCHF': 'AUDCHF=X',
  'AUDNZD': 'AUDNZD=X', 'NZDJPY': 'NZDJPY=X', 'NZDCAD': 'NZDCAD=X',
  'NZDCHF': 'NZDCHF=X', 'CADJPY': 'CADJPY=X', 'CADCHF': 'CADCHF=X',
  'CHFJPY': 'CHFJPY=X',
};
const commoditySymbols = {
  'GOLD', 'SILVER', 'PLATINUM', 'PALLADIUM', 'COPPER', 'OIL', 'BRENT', 'NATGAS',
  'CORN', 'WHEAT', 'SOYBEANS', 'COFFEE', 'SUGAR', 'COTTON',
};
const yahooTf = {
  '1m': ['1m', '5d'], '5m': ['5m', '5d'], '15m': ['15m', '1mo'], '30m': ['30m', '1mo'],
  '1h': ['60m', '3mo'], '4h': ['60m', '6mo'], '1d': ['1d', '2y'],
};
const tfList = ['1m', '5m', '15m', '30m', '1h', '4h', '1d'];
const mtfList = ['5m', '15m', '30m', '1h', '4h', '1d'];
const fxPairs = {
  'EURUSD', 'GBPUSD', 'USDJPY', 'AUDUSD', 'NZDUSD', 'USDCAD', 'USDCHF',
  'EURGBP', 'EURJPY', 'EURCHF', 'EURCAD', 'EURAUD', 'EURNZD',
  'GBPJPY', 'GBPCHF', 'GBPCAD', 'GBPAUD', 'GBPNZD',
  'AUDJPY', 'AUDCAD', 'AUDCHF', 'AUDNZD', 'NZDJPY', 'NZDCAD',
  'NZDCHF', 'CADJPY', 'CADCHF', 'CHFJPY',
};
int decimalsFor(String sym, double price) {
  if (yahooPairs.containsKey(sym)) return decimals(sym);
  if (price >= 1000) return 2;
  if (price >= 10) return 3;
  if (price >= 1) return 4;
  if (price >= 0.1) return 5;
  if (price >= 0.01) return 6;
  return 8;
}

String fmtPrice(double p) => p.toStringAsFixed(decimalsFor('', p));

int decimals(String sym) => sym == 'USDJPY' ? 3 : fxPairs.contains(sym) ? 5 : sym == 'SILVER' ? 3 : 2;

String fmt(dynamic v) {
  final x = num0(v);
  return x > 50 ? x.toStringAsFixed(2) : x >= 0.1 ? x.toStringAsFixed(5) : x.toStringAsFixed(8);
}

String ago(dynamic iso) {
  final t = DateTime.tryParse('$iso')?.toLocal();
  if (t == null) return '';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}


class ScanRow {
  final String coin;
  final double price, change, volume;
  final Analysis a;
  ScanRow(this.coin, this.price, this.change, this.volume, this.a);
}

class Reading {
  final String name, value;
  final int sig; // 1 buy, -1 sell, 0 neutral
  final bool mr; // mean-reversion oscillator (trusted more in ranges, less in strong trends)
  const Reading(this.name, this.value, this.sig, [this.mr = false]);
}

class Analysis {
  final List<Reading> ma, osc, info;
  final int buys, sells, neutrals;
  final double last, atr, adx, score;
  final List<double> sup, res;   // nearest support / resistance levels found on the chart (nearest first)
  Analysis(this.ma, this.osc, this.info, this.buys, this.sells, this.neutrals, this.last, this.atr, this.adx, this.score, this.sup, this.res);
  int get total => buys + sells + neutrals;
  int get side => score >= .2 ? 1 : score <= -.2 ? -1 : 0;
  String get verdict => score >= .5 ? 'STRONG BUY' : score >= .2 ? 'BUY' : score <= -.5 ? 'STRONG SELL' : score <= -.2 ? 'SELL' : 'NEUTRAL';
}

List<double> emaSeries(List<double> v, int n) {
  if (v.isEmpty) return <double>[];
  final k = 2 / (n + 1);
  final out = <double>[v[0]];
  for (var i = 1; i < v.length; i++) {
    out.add(v[i] * k + out[i - 1] * (1 - k));
  }
  return out;
}

List<double> wilder(List<double> v, int n) {
  if (v.isEmpty) return <double>[];
  final out = <double>[v[0]];
  for (var i = 1; i < v.length; i++) {
    out.add(out[i - 1] + (v[i] - out[i - 1]) / n);
  }
  return out;
}

double smaLast(List<double> v, int n) {
  if (v.length < n) return double.nan;
  var s = 0.0;
  for (var i = v.length - n; i < v.length; i++) {
    s += v[i];
  }
  return s / n;
}

List<double> trSeries(List<double> h, List<double> l, List<double> c) {
  final out = <double>[h[0] - l[0]];
  for (var i = 1; i < c.length; i++) {
    out.add(math.max(h[i] - l[i], math.max((h[i] - c[i - 1]).abs(), (l[i] - c[i - 1]).abs())));
  }
  return out;
}

double rsiLast(List<double> c, int n) {
  if (c.length <= n) return double.nan;
  final up = <double>[0], dn = <double>[0];
  for (var i = 1; i < c.length; i++) {
    final d = c[i] - c[i - 1];
    up.add(d > 0 ? d : 0);
    dn.add(d < 0 ? -d : 0);
  }
  final u = wilder(up, n).last, dd = wilder(dn, n).last;
  return dd == 0 ? 100 : 100 - 100 / (1 + u / dd);
}

// Swing-high / swing-low clustering: returns [price, touches] pairs, ascending by price.
List<List<double>> srLevels(List<double> h, List<double> l, double last, double atr) {
  final n = h.length;
  final piv = <double>[];
  for (var i = 3; i < n - 3; i++) {
    var isH = true, isL = true;
    for (var j = 1; j <= 3; j++) {
      if (h[i] <= h[i - j] || h[i] <= h[i + j]) isH = false;
      if (l[i] >= l[i - j] || l[i] >= l[i + j]) isL = false;
    }
    if (isH) piv.add(h[i]);
    if (isL) piv.add(l[i]);
  }
  piv.sort();
  final tol = atr.isNaN || atr <= 0 ? last * 0.002 : atr * 0.5;
  final lv = <List<double>>[];
  for (final p in piv) {
    if (lv.isNotEmpty && (p - lv.last[0]).abs() <= tol) {
      final k = lv.last[1];
      lv.last[0] = (lv.last[0] * k + p) / (k + 1);
      lv.last[1] = k + 1;
    } else {
      lv.add([p, 1.0]);
    }
  }
  return lv;
}

double wmaAt(List<double> v, int end, int p) {
  var acc = 0.0, den = 0.0;
  for (var k = 0; k < p; k++) {
    final w = (p - k).toDouble();
    acc += w * v[end - k];
    den += w;
  }
  return acc / den;
}

List<double> rsiSeries(List<double> c, int n) {
  final up = <double>[0], dn = <double>[0];
  for (var i = 1; i < c.length; i++) {
    final d = c[i] - c[i - 1];
    up.add(d > 0 ? d : 0);
    dn.add(d < 0 ? -d : 0);
  }
  final u = wilder(up, n), w = wilder(dn, n);
  return [for (var i = 0; i < c.length; i++) w[i] == 0 ? 100.0 : 100 - 100 / (1 + u[i] / w[i])];
}

List<double> adxCalc(List<double> h, List<double> l, List<double> c, int n) {
  final tr = trSeries(h, l, c);
  final pdm = <double>[0], ndm = <double>[0];
  for (var i = 1; i < c.length; i++) {
    final up = h[i] - h[i - 1], dn = l[i - 1] - l[i];
    pdm.add(up > dn && up > 0 ? up : 0);
    ndm.add(dn > up && dn > 0 ? dn : 0);
  }
  final a = wilder(tr, n), p = wilder(pdm, n), m = wilder(ndm, n);
  final dx = <double>[];
  var pdiL = 0.0, ndiL = 0.0;
  for (var i = 0; i < c.length; i++) {
    final pdi = a[i] == 0 ? 0.0 : 100 * p[i] / a[i];
    final ndi = a[i] == 0 ? 0.0 : 100 * m[i] / a[i];
    final sum = pdi + ndi;
    dx.add(sum == 0 ? 0.0 : 100 * (pdi - ndi).abs() / sum);
    pdiL = pdi;
    ndiL = ndi;
  }
  return [wilder(dx, n).last, pdiL, ndiL];
}

int supertrendDir(List<double> h, List<double> l, List<double> c) {
  final atr = wilder(trSeries(h, l, c), 10);
  var fu = 0.0, fl = 0.0, dir = 1;
  for (var i = 0; i < c.length; i++) {
    final hl2 = (h[i] + l[i]) / 2;
    final ub = hl2 + 3 * atr[i], lb = hl2 - 3 * atr[i];
    if (i == 0) {
      fu = ub;
      fl = lb;
      continue;
    }
    final pfu = fu, pfl = fl;
    fu = (ub < pfu || c[i - 1] > pfu) ? ub : pfu;
    fl = (lb > pfl || c[i - 1] < pfl) ? lb : pfl;
    if (dir == 1 && c[i] < fl) {
      dir = -1;
    } else if (dir == -1 && c[i] > fu) {
      dir = 1;
    }
  }
  return dir;
}

Analysis analyze(List<Candle> cs, int d) {
  String f(double v) => v.isNaN || v.isInfinite ? 'N/A' : v.toStringAsFixed(d);
  String f1(double v) => v.isNaN || v.isInfinite ? 'N/A' : v.toStringAsFixed(1);
  final n = cs.length;
  final c = cs.map((x) => x.close).toList();
  final h = cs.map((x) => x.high).toList();
  final l = cs.map((x) => x.low).toList();
  final v = cs.map((x) => x.volume).toList();
  final last = c.last;
  final hasVol = v.skip(math.max(0, n - 50)).fold<double>(0, (a, b) => a + b) > 0;
  final ma = <Reading>[], osc = <Reading>[], info = <Reading>[];
  var adxV = double.nan;

  // ---- trend / moving averages
  for (final p in [10, 20, 30, 50, 100, 200]) {
    if (n >= p) {
      final e = emaSeries(c, p).last;
      ma.add(Reading('EMA $p', f(e), last > e ? 1 : -1));
    }
  }
  for (final p in [10, 20, 30, 50, 100, 200]) {
    final sm = smaLast(c, p);
    if (!sm.isNaN) ma.add(Reading('SMA $p', f(sm), last > sm ? 1 : -1));
  }
  if (hasVol) {
    var pv = 0.0, vv = 0.0;
    for (var i = math.max(0, n - 50); i < n; i++) {
      pv += (h[i] + l[i] + c[i]) / 3 * v[i];
      vv += v[i];
    }
    final vw = pv / vv;
    ma.add(Reading('VWAP (50)', f(vw), last > vw ? 1 : -1));
  }
  final st = supertrendDir(h, l, c);
  ma.add(Reading('Supertrend (10,3)', st == 1 ? 'Uptrend' : 'Downtrend', st));

  // ---- oscillators
  final rsi = rsiLast(c, 14);
  osc.add(Reading('RSI (14)', f1(rsi), rsi < 30 ? 1 : rsi > 70 ? -1 : 0, true));

  double kAt(int i) {
    var hh = -1e300, ll = 1e300;
    for (var j = i - 13; j <= i; j++) {
      if (h[j] > hh) hh = h[j];
      if (l[j] < ll) ll = l[j];
    }
    return hh == ll ? 50 : 100 * (c[i] - ll) / (hh - ll);
  }
  if (n >= 16) {
    final k = kAt(n - 1), dd = (kAt(n - 1) + kAt(n - 2) + kAt(n - 3)) / 3;
    osc.add(Reading('Stochastic (14,3)', 'K ${f1(k)} / D ${f1(dd)}', k < 20 ? 1 : k > 80 ? -1 : 0, true));
  }
  if (n >= 20) {
    final tp = <double>[for (var i = 0; i < n; i++) (h[i] + l[i] + c[i]) / 3];
    final sm = smaLast(tp, 20);
    var md = 0.0;
    for (var i = n - 20; i < n; i++) {
      md += (tp[i] - sm).abs();
    }
    md /= 20;
    final cci = md == 0 ? 0.0 : (tp.last - sm) / (0.015 * md);
    osc.add(Reading('CCI (20)', f1(cci), cci < -100 ? 1 : cci > 100 ? -1 : 0, true));
  }
  if (n >= 14) {
    var hh = -1e300, ll = 1e300;
    for (var j = n - 14; j < n; j++) {
      if (h[j] > hh) hh = h[j];
      if (l[j] < ll) ll = l[j];
    }
    final wr = hh == ll ? -50.0 : -100 * (hh - last) / (hh - ll);
    osc.add(Reading('Williams %R (14)', f1(wr), wr < -80 ? 1 : wr > -20 ? -1 : 0, true));
  }
  final e12 = emaSeries(c, 12), e26 = emaSeries(c, 26);
  final macdLine = <double>[for (var i = 0; i < n; i++) e12[i] - e26[i]];
  final macdSig = emaSeries(macdLine, 9);
  final hist = macdLine.last - macdSig.last;
  osc.add(Reading('MACD (12,26,9)', '${f(macdLine.last)} / ${f(macdSig.last)}', hist > 0 ? 1 : hist < 0 ? -1 : 0));
  if (n > 10) {
    final mom = last - c[n - 11];
    osc.add(Reading('Momentum (10)', f(mom), mom > 0 ? 1 : mom < 0 ? -1 : 0));
  }
  if (n >= 34) {
    final hl2 = <double>[for (var i = 0; i < n; i++) (h[i] + l[i]) / 2];
    final ao = smaLast(hl2, 5) - smaLast(hl2, 34);
    osc.add(Reading('Awesome Oscillator', f(ao), ao > 0 ? 1 : -1));
  }
  if (n >= 30) {
    final ax = adxCalc(h, l, c, 14);
    adxV = ax[0];
    osc.add(Reading('ADX (14)', '${f1(ax[0])}  +DI ${f1(ax[1])} / -DI ${f1(ax[2])}', ax[0] > 20 ? (ax[1] > ax[2] ? 1 : -1) : 0));
  }
  if (n >= 20) {
    final mid = smaLast(c, 20);
    var varc = 0.0;
    for (var i = n - 20; i < n; i++) {
      varc += math.pow(c[i] - mid, 2).toDouble();
    }
    final sd = math.sqrt(varc / 20);
    final up = mid + 2 * sd, lo = mid - 2 * sd;
    final pb = up == lo ? 0.5 : (last - lo) / (up - lo);
    osc.add(Reading('Bollinger %B (20,2)', pb.toStringAsFixed(2), pb < 0.05 ? 1 : pb > 0.95 ? -1 : 0, true));
    info.add(Reading('Bollinger bands', '${f(up)} / ${f(mid)} / ${f(lo)}', 0));
  }
  if (n > 21) {
    var hh = -1e300, ll = 1e300;
    for (var j = n - 21; j <= n - 2; j++) {
      if (h[j] > hh) hh = h[j];
      if (l[j] < ll) ll = l[j];
    }
    osc.add(Reading('Donchian break (20)', last > hh ? 'Broke high' : last < ll ? 'Broke low' : 'Inside range', last > hh ? 1 : last < ll ? -1 : 0));
  }
  if (hasVol && n > 15) {
    final tp = <double>[for (var i = 0; i < n; i++) (h[i] + l[i] + c[i]) / 3];
    var pos = 0.0, neg = 0.0;
    for (var i = n - 14; i < n; i++) {
      final raw = tp[i] * v[i];
      if (tp[i] > tp[i - 1]) {
        pos += raw;
      } else if (tp[i] < tp[i - 1]) {
        neg += raw;
      }
    }
    final mfi = neg == 0 ? 100.0 : 100 - 100 / (1 + pos / neg);
    osc.add(Reading('MFI (14)', f1(mfi), mfi < 20 ? 1 : mfi > 80 ? -1 : 0, true));
    final obv = <double>[0];
    for (var i = 1; i < n; i++) {
      obv.add(obv[i - 1] + (c[i] > c[i - 1] ? v[i] : c[i] < c[i - 1] ? -v[i] : 0));
    }
    final oe = emaSeries(obv, 21).last;
    osc.add(Reading('OBV vs EMA21', obv.last > oe ? 'Rising' : 'Falling', obv.last > oe ? 1 : -1));
  }

  // ---- extra indicators
  if (n >= 20) {
    var upT = true, af = 0.02, ep = h[0], sar = l[0];
    for (var i = 1; i < n; i++) {
      sar = sar + af * (ep - sar);
      if (upT) {
        if (l[i] < sar) {
          upT = false;
          sar = ep;
          ep = l[i];
          af = 0.02;
        } else if (h[i] > ep) {
          ep = h[i];
          af = math.min(af + 0.02, 0.2);
        }
      } else {
        if (h[i] > sar) {
          upT = true;
          sar = ep;
          ep = h[i];
          af = 0.02;
        } else if (l[i] < ep) {
          ep = l[i];
          af = math.min(af + 0.02, 0.2);
        }
      }
    }
    ma.add(Reading('Parabolic SAR', f(sar), upT ? 1 : -1));
  }
  if (n >= 80) {
    double hhOf(int from, int to) {
      var m = -1e300;
      for (var j = from; j <= to; j++) {
        if (h[j] > m) m = h[j];
      }
      return m;
    }
    double llOf(int from, int to) {
      var m = 1e300;
      for (var j = from; j <= to; j++) {
        if (l[j] < m) m = l[j];
      }
      return m;
    }
    final tenkan = (hhOf(n - 9, n - 1) + llOf(n - 9, n - 1)) / 2;
    final kijun = (hhOf(n - 26, n - 1) + llOf(n - 26, n - 1)) / 2;
    final e = n - 27; // the cloud shown today was computed 26 bars ago
    final sa = ((hhOf(e - 8, e) + llOf(e - 8, e)) / 2 + (hhOf(e - 25, e) + llOf(e - 25, e)) / 2) / 2;
    final sb = (hhOf(e - 51, e) + llOf(e - 51, e)) / 2;
    final cloudTop = math.max(sa, sb), cloudBot = math.min(sa, sb);
    final sg = last > cloudTop && tenkan > kijun ? 1 : last < cloudBot && tenkan < kijun ? -1 : 0;
    ma.add(Reading('Ichimoku', last > cloudTop ? 'Above cloud' : last < cloudBot ? 'Below cloud' : 'Inside cloud', sg));
  }
  if (n >= 20) {
    final kMid = emaSeries(c, 20).last;
    final a10 = wilder(trSeries(h, l, c), 10).last;
    final kUp = kMid + 2 * a10, kLo = kMid - 2 * a10;
    osc.add(Reading('Keltner channel (20,2)', last > kUp ? 'Above upper' : last < kLo ? 'Below lower' : 'Inside', last > kUp ? 1 : last < kLo ? -1 : 0));
  }
  if (n >= 40) {
    final rs = rsiSeries(c, 14);
    final raw = <double>[];
    for (var i = 27; i < n; i++) {
      var hh = -1e300, ll = 1e300;
      for (var j = i - 13; j <= i; j++) {
        if (rs[j] > hh) hh = rs[j];
        if (rs[j] < ll) ll = rs[j];
      }
      raw.add(hh == ll ? 50.0 : 100 * (rs[i] - ll) / (hh - ll));
    }
    final k = (raw[raw.length - 1] + raw[raw.length - 2] + raw[raw.length - 3]) / 3;
    osc.add(Reading('Stochastic RSI', f1(k), k < 20 ? 1 : k > 80 ? -1 : 0, true));
  }
  if (n >= 30) {
    double avgU(int p) {
      var bp = 0.0, tr = 0.0;
      for (var i = n - p; i < n; i++) {
        final lo = math.min(l[i], c[i - 1]), hi = math.max(h[i], c[i - 1]);
        bp += c[i] - lo;
        tr += hi - lo;
      }
      return tr == 0 ? 0.5 : bp / tr;
    }
    final uo = 100 * (4 * avgU(7) + 2 * avgU(14) + avgU(28)) / 7;
    osc.add(Reading('Ultimate Oscillator', f1(uo), uo < 30 ? 1 : uo > 70 ? -1 : 0, true));
  }
  if (n > 26) {
    var hi = n - 26, lo = n - 26;
    for (var j = n - 26; j < n; j++) {
      if (h[j] >= h[hi]) hi = j;
      if (l[j] <= l[lo]) lo = j;
    }
    final aUp = 100 * (25 - (n - 1 - hi)) / 25, aDn = 100 * (25 - (n - 1 - lo)) / 25;
    final ao = aUp - aDn;
    osc.add(Reading('Aroon (25)', 'Up ${f1(aUp)} / Down ${f1(aDn)}', ao > 50 ? 1 : ao < -50 ? -1 : 0));
  }
  if (n > 14) {
    final e13 = emaSeries(c, 13);
    final bull = h[n - 1] - e13[n - 1], bear = l[n - 1] - e13[n - 1];
    final pBull = h[n - 2] - e13[n - 2], pBear = l[n - 2] - e13[n - 2];
    final rising = e13[n - 1] > e13[n - 2];
    final sg = rising && bear < 0 && bear > pBear ? 1 : !rising && bull > 0 && bull < pBull ? -1 : 0;
    osc.add(Reading('Elder Ray (13)', 'Bull ${f(bull)} / Bear ${f(bear)}', sg));
  }
  if (hasVol && n >= 20) {
    var mfv = 0.0, vs = 0.0;
    for (var i = n - 20; i < n; i++) {
      final rg = h[i] - l[i];
      final clv = rg == 0 ? 0.0 : ((c[i] - l[i]) - (h[i] - c[i])) / rg;
      mfv += clv * v[i];
      vs += v[i];
    }
    final cmf = vs == 0 ? 0.0 : mfv / vs;
    osc.add(Reading('Chaikin Money Flow (20)', cmf.toStringAsFixed(2), cmf > 0.05 ? 1 : cmf < -0.05 ? -1 : 0));
  }

  // ---- more TradingView-style indicators
  if (hasVol && n >= 20) {
    var pv = 0.0, vv = 0.0;
    for (var i = n - 20; i < n; i++) {
      pv += c[i] * v[i];
      vv += v[i];
    }
    final vw = pv / vv;
    ma.add(Reading('VWMA (20)', f(vw), last > vw ? 1 : -1));
  }
  if (hasVol && n >= 23) {
    var sv = 0.0;
    for (var i = n - 22; i <= n - 3; i++) {
      sv += v[i];
    }
    final avgV = sv / 20;
    if (avgV > 0) info.add(Reading('Last closed candle volume', '${(v[n - 2] / avgV).toStringAsFixed(2)}x average', 0));
  }
  if (n >= 12) {
    final dd = <double>[for (var i = n - 3; i < n; i++) 2 * wmaAt(c, i, 4) - wmaAt(c, i, 9)];
    final hma = wmaAt(dd, 2, 3);
    ma.add(Reading('Hull MA (9)', f(hma), last > hma ? 1 : -1));
  }
  if (n >= 60) {
    final t3 = emaSeries(emaSeries(emaSeries(c, 15), 15), 15);
    final tx = (t3[n - 1] - t3[n - 2]) / t3[n - 2] * 100;
    osc.add(Reading('TRIX (15)', tx.toStringAsFixed(4), tx > 0 ? 1 : tx < 0 ? -1 : 0));
  }
  if (n > 13) {
    final roc = (last - c[n - 13]) / c[n - 13] * 100;
    osc.add(Reading('ROC (12)', '${roc.toStringAsFixed(2)}%', roc > 0 ? 1 : roc < 0 ? -1 : 0));
  }
  if (n > 15) {
    var vmp = 0.0, vmm = 0.0, trs = 0.0;
    for (var i = n - 14; i < n; i++) {
      vmp += (h[i] - l[i - 1]).abs();
      vmm += (l[i] - h[i - 1]).abs();
      trs += math.max(h[i] - l[i], math.max((h[i] - c[i - 1]).abs(), (l[i] - c[i - 1]).abs()));
    }
    final viP = trs == 0 ? 1.0 : vmp / trs, viM = trs == 0 ? 1.0 : vmm / trs;
    osc.add(Reading('Vortex (14)', '+${viP.toStringAsFixed(2)} / -${viM.toStringAsFixed(2)}', viP - viM > 0.05 ? 1 : viP - viM < -0.05 ? -1 : 0));
  }
  if (n >= 25) {
    double hMax(int e, int p) {
      var m = -1e300;
      for (var j = e - p + 1; j <= e; j++) {
        if (h[j] > m) m = h[j];
      }
      return m;
    }
    double lMin(int e, int p) {
      var m = 1e300;
      for (var j = e - p + 1; j <= e; j++) {
        if (l[j] < m) m = l[j];
      }
      return m;
    }
    double momAt(int e) {
      final mid = (hMax(e, 20) + lMin(e, 20)) / 2;
      var sm = 0.0;
      for (var j = e - 19; j <= e; j++) {
        sm += c[j];
      }
      return c[e] - (mid + sm / 20) / 2;
    }
    final m1 = momAt(n - 1), m0 = momAt(n - 2);
    final mean20 = smaLast(c, 20);
    var sq = 0.0;
    for (var j = n - 20; j < n; j++) {
      sq += (c[j] - mean20) * (c[j] - mean20);
    }
    final sd = math.sqrt(sq / 20);
    final a20 = wilder(trSeries(h, l, c), 20).last;
    final sqOn = 2 * sd < 1.5 * a20;
    osc.add(Reading('Squeeze Momentum', '${sqOn ? 'Squeeze ON' : 'Squeeze OFF'}, momentum ${m1 > m0 ? 'rising' : 'falling'}',
        m1 > 0 && m1 > m0 ? 1 : m1 < 0 && m1 < m0 ? -1 : 0));
  }
  if (n >= 10) {
    var hao = (cs[0].open + c[0]) / 2;
    var hac = (cs[0].open + h[0] + l[0] + c[0]) / 4;
    final bullHa = <bool>[hac > hao];
    for (var i = 1; i < n; i++) {
      final nc = (cs[i].open + h[i] + l[i] + c[i]) / 4;
      final no = (hao + hac) / 2;
      hao = no;
      hac = nc;
      bullHa.add(hac > hao);
    }
    final b3 = bullHa[n - 1] && bullHa[n - 2] && bullHa[n - 3];
    final s3 = !bullHa[n - 1] && !bullHa[n - 2] && !bullHa[n - 3];
    osc.add(Reading('Heikin-Ashi trend', b3 ? 'Bullish (3 candles)' : s3 ? 'Bearish (3 candles)' : 'Mixed', b3 ? 1 : s3 ? -1 : 0));
  }
  if (n >= 40) {
    final atr22 = wilder(trSeries(h, l, c), 22);
    var dirC = 1;
    var pls = double.nan, pss = double.nan;
    for (var i = 21; i < n; i++) {
      var hh = -1e300, ll = 1e300;
      for (var j = i - 21; j <= i; j++) {
        if (h[j] > hh) hh = h[j];
        if (l[j] < ll) ll = l[j];
      }
      final lsv = hh - 3 * atr22[i], ssv = ll + 3 * atr22[i];
      if (!pss.isNaN) {
        if (c[i] > pss) {
          dirC = 1;
        } else if (c[i] < pls) {
          dirC = -1;
        }
      }
      pls = lsv;
      pss = ssv;
    }
    osc.add(Reading('Chandelier Exit (22,3)', dirC == 1 ? 'Long' : 'Short', dirC));
  }
  if (n >= 50) {
    const win = 50;
    var sx = 0.0, sy = 0.0;
    for (var k = 0; k < win; k++) {
      sx += k;
      sy += c[n - win + k];
    }
    final mx = sx / win, my = sy / win;
    var sxy = 0.0, sxx = 0.0, syy = 0.0;
    for (var k = 0; k < win; k++) {
      final dx = k - mx, dy = c[n - win + k] - my;
      sxy += dx * dy;
      sxx += dx * dx;
      syy += dy * dy;
    }
    final slope = sxx == 0 ? 0.0 : sxy / sxx;
    final r2 = syy == 0 || sxx == 0 ? 0.0 : sxy * sxy / (sxx * syy);
    final pct = my == 0 ? 0.0 : slope * win / my * 100;
    osc.add(Reading('Linear regression (50)', '${pct.toStringAsFixed(1)}% over 50 bars, R2 ${r2.toStringAsFixed(2)}', r2 > 0.5 ? (slope > 0 ? 1 : -1) : 0));
  }
  if (n >= 30) {
    final w = math.min(n, 100);
    var hiF = -1e300, loF = 1e300;
    for (var j = n - w; j < n; j++) {
      if (h[j] > hiF) hiF = h[j];
      if (l[j] < loF) loF = l[j];
    }
    final rg = hiF - loF;
    info.add(Reading('Fib 38.2 / 50 / 61.8 (100 bars)', '${f(hiF - 0.382 * rg)} / ${f(hiF - 0.5 * rg)} / ${f(hiF - 0.618 * rg)}', 0));
  }

  // ---- info
  final atr = wilder(trSeries(h, l, c), 14).last;

  // ---- support / resistance read from the chart
  var lvAll = srLevels(h, l, last, atr);
  final strong = lvAll.where((x) => x[1] >= 2).toList();
  if (strong.length >= 2) lvAll = strong;
  final sups = <double>[for (final x in lvAll.reversed) if (x[0] < last) x[0]];
  final ress = <double>[for (final x in lvAll) if (x[0] > last) x[0]];
  if (atr > 0) {
    final dS = sups.isEmpty ? 1e9 : (last - sups.first) / atr;
    final dR = ress.isEmpty ? 1e9 : (ress.first - last) / atr;
    final txt = '${sups.isEmpty ? 'S -' : 'S ${f(sups.first)} (${dS.toStringAsFixed(1)} ATR)'}  ${ress.isEmpty ? 'R -' : 'R ${f(ress.first)} (${dR.toStringAsFixed(1)} ATR)'}';
    osc.add(Reading('Support / Resistance', txt, dS <= 0.6 ? 1 : dR <= 0.6 ? -1 : 0, true));
  }
  if (sups.isNotEmpty) info.add(Reading('Support levels', sups.take(3).map(f).join(' / '), 0));
  if (ress.isNotEmpty) info.add(Reading('Resistance levels', ress.take(3).map(f).join(' / '), 0));

  // ---- candlestick pattern on the latest candles
  if (n >= 4) {
    final i = n - 1;
    final body = (c[i] - cs[i].open).abs(), rg = h[i] - l[i];
    final upW = h[i] - math.max(c[i], cs[i].open), loW = math.min(c[i], cs[i].open) - l[i];
    final pBody = (c[i - 1] - cs[i - 1].open).abs();
    final bigPrev = (c[i - 2] - cs[i - 2].open).abs();
    var name = 'None', sg = 0;
    if (c[i - 2] < cs[i - 2].open && bigPrev > atr * 0.6 && pBody < bigPrev * 0.4 && c[i] > cs[i].open && c[i] > (c[i - 2] + cs[i - 2].open) / 2) {
      name = 'Morning star';
      sg = 1;
    } else if (c[i - 2] > cs[i - 2].open && bigPrev > atr * 0.6 && pBody < bigPrev * 0.4 && c[i] < cs[i].open && c[i] < (c[i - 2] + cs[i - 2].open) / 2) {
      name = 'Evening star';
      sg = -1;
    } else if (c[i - 1] < cs[i - 1].open && c[i] > cs[i].open && c[i] >= cs[i - 1].open && cs[i].open <= c[i - 1] && body > pBody) {
      name = 'Bullish engulfing';
      sg = 1;
    } else if (c[i - 1] > cs[i - 1].open && c[i] < cs[i].open && c[i] <= cs[i - 1].open && cs[i].open >= c[i - 1] && body > pBody) {
      name = 'Bearish engulfing';
      sg = -1;
    } else if (rg > 0 && body > 0 && loW > 2 * body && upW < 0.25 * rg) {
      name = 'Hammer';
      sg = 1;
    } else if (rg > 0 && body > 0 && upW > 2 * body && loW < 0.25 * rg) {
      name = 'Shooting star';
      sg = -1;
    } else if (rg > 0 && body < 0.1 * rg) {
      name = 'Doji';
    }
    osc.add(Reading('Candle pattern', name, sg));
  }
  info.add(Reading('ATR (14)', '${f(atr)}  (${(atr / last * 100).toStringAsFixed(2)}%)', 0));
  if (n > 2) {
    final p = (h[n - 2] + l[n - 2] + c[n - 2]) / 3;
    info.add(Reading('Pivot / R1 / S1', '${f(p)} / ${f(2 * p - l[n - 2])} / ${f(2 * p - h[n - 2])}', 0));
  }

  // Mean-reversion votes (RSI, MFI, Bollinger %B, CCI, Stochastic, Williams %R, Stochastic RSI, Ultimate Oscillator and
  // the support/resistance position) were right LESS often than a coin flip in the one-month server Lab: -2 to -5 points
  // in every style and in the forward test. They stay visible (marked "info only") but no longer count towards the verdict.
  var b = 0, s = 0, z = 0;
  for (final r in [...ma, ...osc]) {
    if (r.mr) continue;
    if (r.sig > 0) {
      b++;
    } else if (r.sig < 0) {
      s++;
    } else {
      z++;
    }
  }
  // Weights follow the server Lab: the indicators with the clearest edge count more, candle patterns (no edge) count less.
  const edgeWeight = <String, double>{
    'Keltner channel (20,2)': 2.0, 'Donchian break (20)': 2.0, 'ADX (14)': 1.5, 'Ichimoku': 1.5, 'SMA 50': 1.5, 'Candle pattern': 0.5,
  };
  var wsum = 0.0, ssum = 0.0;
  for (final r in [...ma, ...osc]) {
    if (r.mr) continue;
    final w = edgeWeight[r.name] ?? 1.0;
    wsum += w;
    ssum += w * r.sig;
  }
  final score = wsum == 0 ? 0.0 : ssum / wsum;
  return Analysis(ma, osc, info, b, s, z, last, atr, adxV, score, sups.take(3).toList(), ress.take(3).toList());
}

Future<List<Candle>> fetchCandles(String sym, String tf) async {
  if (!yahooPairs.containsKey(sym)) {
    final pair = futSymbols[sym] ?? '${sym}USDT';
    final q = {'symbol': pair, 'interval': tf, 'limit': '300'};
    var r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/klines', q)).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      r = await http.get(Uri.https('api.binance.com', '/api/v3/klines', q)).timeout(const Duration(seconds: 15));   // spot fallback
    }
    if (r.statusCode != 200) throw 'Binance data unavailable for $sym (HTTP ${r.statusCode}). It may be blocked on your network.';
    return (jsonDecode(r.body) as List)
        .map((x) => Candle(DateTime.fromMillisecondsSinceEpoch((x[0] as num).toInt()), double.parse('${x[1]}'),
            double.parse('${x[2]}'), double.parse('${x[3]}'), double.parse('${x[4]}'), double.parse('${x[5]}')))
        .toList();
  }
  final ySym = yahooPairs[sym]!;
  final cfg = yahooTf[tf] ?? ['1m', '1d'];
  final uri = Uri.https('query1.finance.yahoo.com', '/v8/finance/chart/$ySym', {'range': cfg[1], 'interval': cfg[0]});
  final r = await http.get(uri, headers: {'User-Agent': 'Mozilla/5.0'}).timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw '$sym data unavailable (HTTP ${r.statusCode}). Free source may be rate-limited or the market is closed.';
  final result = (jsonDecode(r.body)['chart']['result'] as List?) ?? [];
  if (result.isEmpty) throw '$sym has no data right now (market may be closed).';
  final root = result[0];
  final times = (root['timestamp'] as List?) ?? [];
  final q = root['indicators']['quote'][0];
  final os = q['open'] as List? ?? [], hs = q['high'] as List? ?? [], ls = q['low'] as List? ?? [], cs = q['close'] as List? ?? [], vs = q['volume'] as List? ?? [];
  var list = <Candle>[];
  for (var i = 0; i < times.length; i++) {
    if ([os[i], hs[i], ls[i], cs[i]].any((x) => x == null)) continue;
    final vol = i < vs.length && vs[i] != null ? (vs[i] as num).toDouble() : 0.0;
    list.add(Candle(DateTime.fromMillisecondsSinceEpoch((times[i] as num).toInt() * 1000), (os[i] as num).toDouble(),
        (hs[i] as num).toDouble(), (ls[i] as num).toDouble(), (cs[i] as num).toDouble(), vol));
  }
  if (tf == '4h') list = aggregateCandles(list, 4);
  return list.takeLast(300);
}

List<Candle> aggregateCandles(List<Candle> src, int hours) {
  final ms = hours * 3600 * 1000;
  final out = <Candle>[];
  int? key;
  for (final c in src) {
    final k = c.time.millisecondsSinceEpoch ~/ ms;
    if (key == k && out.isNotEmpty) {
      final p = out.last;
      out[out.length - 1] = Candle(p.time, p.open, math.max(p.high, c.high), math.min(p.low, c.low), c.close, p.volume + c.volume);
    } else {
      out.add(c);
      key = k;
    }
  }
  return out;
}


// ---------- news, sentiment and web data ----------
const newsFeeds = {
  'CoinDesk': 'https://www.coindesk.com/arc/outboundfeeds/rss/',
  'Cointelegraph': 'https://cointelegraph.com/rss',
  'Decrypt': 'https://decrypt.co/feed',
  'FXStreet': 'https://www.fxstreet.com/rss/news',
  'ForexLive': 'https://www.forexlive.com/feed/news',
  'CNBC': 'https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=10000664',
  'BBC Business': 'https://feeds.bbci.co.uk/news/business/rss.xml',
};
const bullWords = ['surge', 'rally', 'soar', 'approve', 'inflow', 'adoption', 'rate cut', 'beats', 'record high', 'gains', 'bullish', 'jumps', 'rebound', 'recovers', 'upgrade', 'breakout', 'etf approval'];
const bearWords = ['crash', 'plunge', 'hack', 'exploit', 'ban ', 'lawsuit', 'sues', 'rate hike', 'liquidat', 'fears', 'selloff', 'sell-off', 'bearish', 'slump', 'tumbles', 'warns', 'outflow', 'downgrade', 'sanction', 'default'];
const macroWords = ['fed ', 'fomc', 'inflation', 'cpi', 'dollar', 'powell', 'yields', 'tariff'];
const coinKeys = {
  'BTC': ['bitcoin', 'btc'], 'ETH': ['ethereum', 'ether '], 'SOL': ['solana'], 'BNB': ['bnb', 'binance'], 'XRP': ['xrp', 'ripple'],
  'DOGE': ['dogecoin', 'doge'], 'GOLD': ['gold'], 'SILVER': ['silver'], 'OIL': ['oil', 'crude', 'opec', 'brent'],
  'EURUSD': ['euro ', 'ecb', 'eur/usd'], 'GBPUSD': ['sterling', 'boe', 'gbp', 'pound'], 'USDJPY': ['yen', 'boj', 'jpy'],
  'AUDUSD': ['aussie', 'rba', 'aud '], 'USDCAD': ['loonie', 'boc', 'canadian dollar'],
};
const symCurrencies = {
  'EURUSD': ['EUR', 'USD'], 'GBPUSD': ['GBP', 'USD'], 'USDJPY': ['USD', 'JPY'], 'AUDUSD': ['AUD', 'USD'], 'USDCAD': ['USD', 'CAD'],
};

List<String> keysFor(String sym) => coinKeys[sym] ?? [sym.length >= 4 ? sym.toLowerCase() : ' ${sym.toLowerCase()} '];

class NewsItem {
  final String title, source;
  final DateTime? time;
  final int score;
  NewsItem(this.title, this.source, this.time, this.score);
}

class EconEvent {
  final String title, country, forecast, previous;
  final DateTime time;
  EconEvent(this.title, this.country, this.time, this.forecast, this.previous);
}

int scoreTitle(String t) {
  final x = ' ${t.toLowerCase()} ';
  var sc = 0;
  for (final w in bullWords) {
    if (x.contains(w)) sc++;
  }
  for (final w in bearWords) {
    if (x.contains(w)) sc--;
  }
  return sc;
}

String unescapeXml(String s) => s
    .replaceAll('<![CDATA[', '')
    .replaceAll(']]>', '')
    .replaceAll('&amp;', '&')
    .replaceAll('&#39;', "'")
    .replaceAll('&#8217;', "'")
    .replaceAll('&quot;', '"')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .trim();

DateTime? parseRfc822(String s) {
  final m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2})(?::(\d{2}))?').firstMatch(s);
  if (m == null) return DateTime.tryParse(s);
  const months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  final mo = months.indexOf(m.group(2)!.toLowerCase()) + 1;
  if (mo == 0) return null;
  var t = DateTime.utc(int.parse(m.group(3)!), mo, int.parse(m.group(1)!), int.parse(m.group(4)!), int.parse(m.group(5)!), int.parse(m.group(6) ?? '0'));
  final z = RegExp(r'([+-])(\d{2})(\d{2})\s*$').firstMatch(s.trim());
  if (z != null) {
    final off = Duration(hours: int.parse(z.group(2)!), minutes: int.parse(z.group(3)!));
    t = z.group(1) == '+' ? t.subtract(off) : t.add(off);
  }
  return t;
}

List<NewsItem> parseRss(String body, String source) {
  final out = <NewsItem>[];
  for (final m in RegExp(r'<item[\s>](.*?)</item>', dotAll: true).allMatches(body)) {
    final blk = m.group(1) ?? '';
    final t = RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true).firstMatch(blk)?.group(1);
    if (t == null) continue;
    final d = RegExp(r'<pubDate[^>]*>(.*?)</pubDate>', dotAll: true).firstMatch(blk)?.group(1);
    final title = unescapeXml(t);
    out.add(NewsItem(title, source, d == null ? null : parseRfc822(d.trim()), scoreTitle(title)));
  }
  return out;
}

Future<List<NewsItem>> fetchNews() async {
  final res = await Future.wait(newsFeeds.entries.map<Future<List<NewsItem>>>((e) async {
    try {
      final r = await http.get(Uri.parse(e.value), headers: {'User-Agent': 'Mozilla/5.0'}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return <NewsItem>[];
      return parseRss(r.body, e.key).take(20).toList();
    } catch (_) {
      return <NewsItem>[];
    }
  }));
  final all = [for (final l in res) ...l];
  all.sort((a, b) => (b.time ?? DateTime(2000)).compareTo(a.time ?? DateTime(2000)));
  return all.take(120).toList();
}

Future<Map<String, dynamic>?> fetchFng() async {
  try {
    final r = await http.get(Uri.parse('https://api.alternative.me/fng/?limit=2')).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return null;
    final d = jsonDecode(r.body)['data'] as List;
    return {'value': int.parse('${d[0]['value']}'), 'label': '${d[0]['value_classification']}', 'prev': d.length > 1 ? int.parse('${d[1]['value']}') : null};
  } catch (_) {
    return null;
  }
}

Future<List<EconEvent>> fetchEvents() async {
  try {
    final r = await http.get(Uri.parse('https://nfs.faireconomy.media/ff_calendar_thisweek.json'), headers: {'User-Agent': 'Mozilla/5.0'}).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return [];
    final out = <EconEvent>[];
    for (final e in jsonDecode(r.body) as List) {
      if (e['impact'] != 'High') continue;
      final t = DateTime.tryParse('${e['date']}');
      if (t == null) continue;
      out.add(EconEvent('${e['title']}', '${e['country']}', t.toLocal(), '${e['forecast'] ?? ''}', '${e['previous'] ?? ''}'));
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  } catch (_) {
    return [];
  }
}

// Binance futures positioning: funding rate (%), open interest (coins), long/short account ratio
Future<Map<String, double>> fetchFutMeta(String coin) async {
  final pair = futSymbols[coin] ?? '${coin}USDT';
  final out = <String, double>{};
  try {
    final r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/premiumIndex', {'symbol': pair})).timeout(const Duration(seconds: 10));
    if (r.statusCode == 200) out['funding'] = double.parse('${jsonDecode(r.body)['lastFundingRate']}') * 100;
  } catch (_) {}
  try {
    final r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/openInterest', {'symbol': pair})).timeout(const Duration(seconds: 10));
    if (r.statusCode == 200) out['oi'] = double.parse('${jsonDecode(r.body)['openInterest']}');
  } catch (_) {}
  try {
    final r = await http.get(Uri.https('fapi.binance.com', '/futures/data/globalLongShortAccountRatio', {'symbol': pair, 'period': '1h', 'limit': '1'})).timeout(const Duration(seconds: 10));
    if (r.statusCode == 200) {
      final d = jsonDecode(r.body) as List;
      if (d.isNotEmpty) out['ls'] = double.parse('${d[0]['longShortRatio']}');
    }
  } catch (_) {}
  return out;
}

String compactNum(double v) => v >= 1e9 ? '${(v / 1e9).toStringAsFixed(2)}B' : v >= 1e6 ? '${(v / 1e6).toStringAsFixed(2)}M' : v >= 1e3 ? '${(v / 1e3).toStringAsFixed(1)}K' : v.toStringAsFixed(2);

String hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String untilText(DateTime t) {
  final d = t.difference(DateTime.now());
  final a = d.abs();
  final txt = a.inDays >= 1 ? '${a.inDays}d ${a.inHours % 24}h' : a.inHours >= 1 ? '${a.inHours}h ${a.inMinutes % 60}m' : '${a.inMinutes}m';
  return d.isNegative ? '$txt ago' : 'in $txt';
}

// Stop / target using chart support and resistance when they are close enough to be useful.
List<double> tradePlan(Analysis a) {
  final side = a.side;
  var sl = a.last - side * 1.5 * a.atr;
  final lvl = side == 1 ? (a.sup.isEmpty ? double.nan : a.sup.first - 0.2 * a.atr) : (a.res.isEmpty ? double.nan : a.res.first + 0.2 * a.atr);
  if (!lvl.isNaN) {
    final dist = (a.last - lvl).abs();
    if (dist >= 0.8 * a.atr && dist <= 3 * a.atr) sl = lvl;
  }
  final risk = (a.last - sl).abs();
  var tp = a.last + side * 2 * risk;
  final tgt = side == 1 ? (a.res.isEmpty ? double.nan : a.res.first) : (a.sup.isEmpty ? double.nan : a.sup.first);
  if (!tgt.isNaN) {
    final dist = (tgt - a.last).abs();
    if (dist >= 1.2 * risk && dist < 2 * risk) tp = tgt;
  }
  return [sl, tp, risk == 0 ? 0.0 : (tp - a.last).abs() / risk];
}


// ---------- custom price alerts ----------
class PriceAlert {
  final int id;
  final String sym, note;
  final double price;
  final bool above; // true: notify when price rises to the target, false: when it falls to it
  bool done;
  DateTime? firedAt;
  PriceAlert(this.id, this.sym, this.price, this.above, this.note, {this.done = false, this.firedAt});
  Map<String, dynamic> toJson() => {'id': id, 'sym': sym, 'price': price, 'above': above, 'note': note, 'done': done, 'fired': firedAt?.toIso8601String()};
  factory PriceAlert.fromJson(Map<String, dynamic> j) => PriceAlert(
        (j['id'] as num).toInt(), '${j['sym']}', (j['price'] as num).toDouble(), j['above'] == true, '${j['note'] ?? ''}',
        done: j['done'] == true, firedAt: j['fired'] == null ? null : DateTime.tryParse('${j['fired']}'));
}

final FlutterLocalNotificationsPlugin notifier = FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  try {
    const init = InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher'));
    await notifier.initialize(init);
    await notifier.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  } catch (_) {}
}

Future<void> notify(int id, String title, String body) async {
  try {
    const details = NotificationDetails(
      android: AndroidNotificationDetails('price_alerts', 'Price alerts',
          channelDescription: 'Tells you when a price you chose is reached', importance: Importance.max, priority: Priority.high, playSound: true, enableVibration: true),
    );
    await notifier.show(id, title, body, details);
  } catch (_) {}
}

Future<double?> fetchPrice(String sym) async {
  try {
    if (!yahooPairs.containsKey(sym)) {
      final pair = futSymbols[sym] ?? '${sym}USDT';
      var r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/ticker/price', {'symbol': pair})).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        r = await http.get(Uri.https('api.binance.com', '/api/v3/ticker/price', {'symbol': pair})).timeout(const Duration(seconds: 10));
      }
      if (r.statusCode != 200) return null;
      return double.parse('${jsonDecode(r.body)['price']}');
    }
    final r = await http
        .get(Uri.https('query1.finance.yahoo.com', '/v8/finance/chart/${yahooPairs[sym]}', {'range': '1d', 'interval': '5m'}), headers: {'User-Agent': 'Mozilla/5.0'})
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    return (jsonDecode(r.body)['chart']['result'][0]['meta']['regularMarketPrice'] as num).toDouble();
  } catch (_) {
    return null;
  }
}


// ---------- in-app paper trading ----------
const paperStart = 10000.0;
const paperRisk = 0.01;      // 1% of the virtual account risked per trade
const paperCostR = 0.05;     // fees and slippage, same as the bot
const paperHoldHours = {'1m': 2, '5m': 6, '15m': 12, '30m': 24, '1h': 48, '4h': 120, '1d': 240};

double? cleanNum(double? v) => v == null || v.isNaN || v.isInfinite ? null : v;

class AppTrade {
  final int id, side, buys, sells, neutrals, mood;
  final String coin, tf, source, verdict;
  final double entry, sl, tp, score, riskCash;
  final double? adx, atrPct, rvol, ext;
  final int quality, htfAgree, btc;
  final DateTime opened;
  String status = 'open', reason = '';
  double mfe = 0, mae = 0, exitPx = 0, r = 0;
  bool ambiguous = false;
  DateTime? closed;

  AppTrade({required this.id, required this.coin, required this.tf, required this.source, required this.verdict,
      required this.side, required this.buys, required this.sells, required this.neutrals, required this.mood,
      required this.entry, required this.sl, required this.tp, required this.score, required this.riskCash,
      required this.adx, required this.atrPct, required this.opened,
      this.rvol, this.ext, this.quality = 0, this.htfAgree = 0, this.btc = 0});

  bool get isOpen => status == 'open';
  double get riskPx => (entry - sl).abs();
  double get pnl => r * riskCash;
  double get plannedRr => riskPx == 0 ? 0 : (tp - entry).abs() / riskPx;

  Map<String, dynamic> toJson() => {
        'id': id, 'coin': coin, 'tf': tf, 'source': source, 'verdict': verdict, 'side': side, 'buys': buys,
        'sells': sells, 'neutrals': neutrals, 'mood': mood, 'entry': entry, 'sl': sl, 'tp': tp, 'score': score,
        'risk': riskCash, 'adx': cleanNum(adx), 'atrPct': cleanNum(atrPct), 'opened': opened.toIso8601String(),
        'status': status, 'reason': reason, 'mfe': mfe, 'mae': mae, 'exit': exitPx, 'r': r, 'amb': ambiguous,
        'closed': closed?.toIso8601String(),
        'rvol': cleanNum(rvol), 'ext': cleanNum(ext), 'q': quality, 'htf': htfAgree, 'btc': btc,
      };

  factory AppTrade.fromJson(Map<String, dynamic> j) {
    final t = AppTrade(
      id: (j['id'] as num).toInt(), coin: '${j['coin']}', tf: '${j['tf']}', source: '${j['source'] ?? 'scanner'}',
      verdict: '${j['verdict'] ?? ''}', side: (j['side'] as num).toInt(), buys: (j['buys'] as num?)?.toInt() ?? 0,
      sells: (j['sells'] as num?)?.toInt() ?? 0, neutrals: (j['neutrals'] as num?)?.toInt() ?? 0,
      mood: (j['mood'] as num?)?.toInt() ?? 0, entry: num0(j['entry']), sl: num0(j['sl']), tp: num0(j['tp']),
      score: num0(j['score']), riskCash: num0(j['risk']), adx: (j['adx'] as num?)?.toDouble(),
      atrPct: (j['atrPct'] as num?)?.toDouble(), opened: DateTime.tryParse('${j['opened']}') ?? DateTime.now(),
      rvol: (j['rvol'] as num?)?.toDouble(), ext: (j['ext'] as num?)?.toDouble(), quality: (j['q'] as num?)?.toInt() ?? 0,
      htfAgree: (j['htf'] as num?)?.toInt() ?? 0, btc: (j['btc'] as num?)?.toInt() ?? 0,
    );
    t.status = '${j['status'] ?? 'open'}';
    t.reason = '${j['reason'] ?? ''}';
    t.mfe = num0(j['mfe']);
    t.mae = num0(j['mae']);
    t.exitPx = num0(j['exit']);
    t.r = num0(j['r']);
    t.ambiguous = j['amb'] == true;
    t.closed = j['closed'] == null ? null : DateTime.tryParse('${j['closed']}');
    return t;
  }
}

/// Walks candles after the entry candle. Same-candle SL and TP counts as SL (pessimistic). Returns true if closed.
bool settleTrade(AppTrade t, List<Candle> cs) {
  final risk = t.riskPx == 0 ? 1e-12 : t.riskPx;
  var mfe = t.mfe, mae = t.mae;
  double? exitPx;
  var reason = '', amb = false;
  DateTime? when;
  for (final c in cs) {
    if (!c.time.isAfter(t.opened)) continue;
    final fav = t.side == 1 ? c.high - t.entry : t.entry - c.low;
    final adv = t.side == 1 ? t.entry - c.low : c.high - t.entry;
    mfe = math.max(mfe, fav / risk);
    mae = math.max(mae, adv / risk);
    final hitSl = t.side == 1 ? c.low <= t.sl : c.high >= t.sl;
    final hitTp = t.side == 1 ? c.high >= t.tp : c.low <= t.tp;
    if (hitSl) {
      exitPx = t.sl; reason = 'SL'; when = c.time; amb = hitTp;
      break;
    }
    if (hitTp) {
      exitPx = t.tp; reason = 'TP'; when = c.time;
      break;
    }
  }
  t.mfe = mfe;
  t.mae = mae;
  final holdMin = (paperHoldHours[t.tf] ?? 48) * 60;
  if (exitPx == null && cs.isNotEmpty && DateTime.now().difference(t.opened).inMinutes > holdMin) {
    exitPx = cs.last.close; reason = 'TIMEOUT'; when = DateTime.now();
  }
  if (exitPx == null) return false;
  t.exitPx = exitPx;
  t.reason = reason;
  t.ambiguous = amb;
  t.closed = when;
  t.status = 'closed';
  t.r = (exitPx - t.entry) * t.side / risk - paperCostR;
  return true;
}

class PStats {
  int n = 0, wins = 0, tp = 0, sl = 0, timeouts = 0;
  double sumR = 0, grossWin = 0, grossLoss = 0;
  PStats(Iterable<AppTrade> list) {
    for (final t in list.where((x) => !x.isOpen)) {
      n++;
      sumR += t.r;
      if (t.r > 0) { wins++; grossWin += t.r; } else { grossLoss += -t.r; }
      if (t.reason == 'TP') tp++;
      if (t.reason == 'SL') sl++;
      if (t.reason == 'TIMEOUT') timeouts++;
    }
  }
  double get winPct => n == 0 ? 0 : 100.0 * wins / n;
  double get avgR => n == 0 ? 0 : sumR / n;
  double get pf => grossLoss == 0 ? (grossWin > 0 ? 99.0 : 0.0) : grossWin / grossLoss;
}

String csvCell(dynamic v) {
  if (v == null) return '';
  final t = '$v';
  return t.contains(',') || t.contains('"') || t.contains('\n') ? '"${t.replaceAll('"', '""')}"' : t;
}

String tradesToCsv(List<AppTrade> trades) {
  const cols = ['id', 'status', 'opened_utc', 'closed_utc', 'hours_held', 'symbol', 'strategy', 'tf', 'side', 'verdict', 'score',
    'entry', 'sl', 'tp', 'risk_pct', 'planned_rr', 'exit_price', 'exit_reason', 'same_candle_sl_tp', 'r_multiple', 'pnl_usd',
    'mfe_r', 'mae_r', 'buys', 'neutrals', 'sells', 'adx', 'atr_pct', 'news_mood', 'hour_utc', 'weekday',
    'quality', 'htf_agree', 'rvol', 'ext_atr', 'btc_regime'];
  String r(double? v, int n) => v == null ? '' : v.toStringAsFixed(n);
  final out = StringBuffer(cols.join(',')).toString();
  final lines = <String>[out];
  for (final t in trades) {
    final u = t.opened.toUtc();
    final done = !t.isOpen;
    final row = [
      t.id, t.status, u.toIso8601String(), t.closed?.toUtc().toIso8601String(),
      done && t.closed != null ? r(t.closed!.difference(t.opened).inMinutes / 60, 2) : '',
      t.coin, 'App ${t.source}', t.tf, t.side == 1 ? 'BUY' : 'SELL', t.verdict, r(t.score, 3),
      t.entry, t.sl, t.tp, r(t.entry == 0 ? null : t.riskPx / t.entry * 100, 3), r(t.plannedRr, 2),
      done ? t.exitPx : '', done ? t.reason : '', done ? t.ambiguous : '', done ? r(t.r, 3) : '', done ? r(t.pnl, 2) : '',
      r(t.mfe, 2), r(t.mae, 2), t.buys, t.neutrals, t.sells, r(t.adx, 1), r(t.atrPct, 3), t.mood, u.hour, u.weekday,
      t.quality, t.htfAgree, r(t.rvol, 2), r(t.ext, 2), t.btc,
    ];
    lines.add(row.map(csvCell).join(','));
  }
  return lines.join('\n') + '\n';
}

// ---------- durable storage (files in the app's own folder, plus SharedPreferences as a fallback) ----------
Future<String?> readStore(String name) async {
  try {
    final d = await getApplicationDocumentsDirectory();
    final f = File('${d.path}/$name');
    if (await f.exists()) return await f.readAsString();
  } catch (_) {}
  return null;
}

Future<bool> writeStore(String name, String text) async {
  try {
    final d = await getApplicationDocumentsDirectory();
    final tmp = File('${d.path}/$name.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename('${d.path}/$name');         // write then rename, so a crash never leaves half a file
    return true;
  } catch (_) {
    return false;
  }
}

// ---------- Signal Lab: scores every indicator and every trading style against what price did next ----------
const labHorizonBars = 6;       // judged 6 candles after the signal
const labRaceAtr = 1.5;         // target and stop distance for the race test, in ATR

String styleOf(String tf) => (tf == '1m' || tf == '5m' || tf == '15m') ? 'Scalping' : (tf == '30m' || tf == '1h') ? 'Intraday' : tf == '4h' ? 'Swing' : 'Position';

int barMs(String tf) => (const {'1m': 1, '5m': 5, '15m': 15, '30m': 30, '1h': 60, '4h': 240, '1d': 1440}[tf] ?? 60) * 60000;

String categoryOf(String n) {
  const trend = ['EMA', 'SMA', 'Supertrend', 'Parabolic', 'Ichimoku', 'Hull', 'Linear regression', 'Heikin', 'Chandelier', 'Aroon', 'Vortex', 'ADX', 'TRIX'];
  const vol = ['VWAP', 'VWMA', 'MFI', 'OBV', 'Chaikin', 'Last closed candle volume'];
  const brk = ['Bollinger', 'Donchian', 'Keltner', 'Squeeze'];
  const sr = ['Support', 'Fib', 'Pivot'];
  if (n.startsWith('OVERALL')) return 'Overall verdict';
  if (n.startsWith('Candle pattern')) return 'Candle patterns';
  if (vol.any(n.startsWith)) return 'Volume';
  if (brk.any(n.startsWith)) return 'Breakout / volatility';
  if (sr.any(n.startsWith)) return 'Support / resistance';
  if (trend.any(n.startsWith)) return 'Trend';
  return 'Momentum / oscillators';
}

class LabSnap {
  final String coin, tf;
  final DateTime t0;               // when the signal candle closed
  final double price, atr;
  final Map<String, int> votes;    // indicator name -> +1 buy / -1 sell (neutral votes are not stored)
  double move = 0;                 // price change after the horizon, in ATR
  int race = 0;                    // +1 reached +1.5 ATR first, -1 reached -1.5 ATR first, 0 neither or same candle
  LabSnap(this.coin, this.tf, this.t0, this.price, this.atr, this.votes);
  Map<String, dynamic> toJson() => {'c': coin, 'tf': tf, 't': t0.millisecondsSinceEpoch, 'p': price, 'a': atr, 'v': votes, 'm': move, 'r': race};
  factory LabSnap.fromJson(Map<String, dynamic> j) {
    final x = LabSnap('${j['c']}', '${j['tf']}', DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()), num0(j['p']), num0(j['a']),
        {for (final e in (j['v'] as Map).entries) '${e.key}': (e.value as num).toInt()});
    x.move = num0(j['m']);
    x.race = (j['r'] as num?)?.toInt() ?? 0;
    return x;
  }
}

/// 0 = not ready yet, 1 = scored, 2 = discard (history no longer reaches back far enough)
int evalSnap(LabSnap s, List<Candle> cs) {
  final bar = barMs(s.tf);
  final end = s.t0.add(Duration(milliseconds: bar * labHorizonBars));
  if (DateTime.now().isBefore(end)) return 0;
  if (cs.isEmpty || cs.first.time.isAfter(s.t0)) return 2;
  final up = s.price + labRaceAtr * s.atr, dn = s.price - labRaceAtr * s.atr;
  var race = 0, decided = false;
  double? closeH;
  for (final c in cs) {
    if (c.time.isBefore(s.t0)) continue;
    if (c.time.add(Duration(milliseconds: bar)).isAfter(end)) break;
    if (!decided) {
      final hu = c.high >= up, hd = c.low <= dn;
      if (hu && !hd) { race = 1; decided = true; }
      else if (hd && !hu) { race = -1; decided = true; }
      else if (hu && hd) { race = 0; decided = true; }     // both in one candle: unknowable, counts as neither
    }
    closeH = c.close;
  }
  if (closeH == null) return 2;
  s.move = s.atr > 0 ? (closeH - s.price) / s.atr : 0;
  s.race = race;
  return 1;
}

/// aggregate row: [n, directionHits, raceWins, raceLosses, sumSignedMoveAtr]
void labAdd(Map<String, List<double>> agg, LabSnap s) {
  final style = styleOf(s.tf);
  s.votes.forEach((name, sig) {
    for (final key in ['$name|$style', '$name|All']) {
      final a = agg.putIfAbsent(key, () => [0, 0, 0, 0, 0]);
      a[0]++;
      if (s.move * sig > 0) a[1]++;
      if (s.race == sig) {
        a[2]++;
      } else if (s.race == -sig) {
        a[3]++;
      }
      a[4] += s.move * sig;
    }
  });
}

String labAggCsv(Map<String, List<double>> agg) {
  final lines = ['indicator,category,style,signals,direction_accuracy_pct,race_wins,race_losses,race_win_pct,avg_move_atr'];
  final keys = agg.keys.toList()..sort();
  for (final k in keys) {
    final a = agg[k]!, i = k.lastIndexOf('|');
    final name = k.substring(0, i), style = k.substring(i + 1);
    final den = a[2] + a[3];
    lines.add([csvCell(name), csvCell(categoryOf(name)), style, a[0].toInt(), (100 * a[1] / a[0]).toStringAsFixed(1), a[2].toInt(), a[3].toInt(),
      den > 0 ? (100 * a[2] / den).toStringAsFixed(1) : '', (a[4] / a[0]).toStringAsFixed(3)].join(','));
  }
  return lines.join('\n') + '\n';
}

String labRowsCsv(List<LabSnap> rows) {
  final names = <String>{for (final r in rows) ...r.votes.keys}.toList()..sort();
  final head = ['time_utc', 'coin', 'tf', 'style', 'price', 'atr', 'move_atr', 'race', ...names.map(csvCell)];
  final lines = [head.join(',')];
  for (final r in rows) {
    lines.add([r.t0.toUtc().toIso8601String(), r.coin, r.tf, styleOf(r.tf), r.price, r.atr, r.move.toStringAsFixed(3), r.race,
      ...names.map((n) => r.votes[n] ?? 0)].join(','));
  }
  return lines.join('\n') + '\n';
}

class SignalApp extends StatelessWidget {
  const SignalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Signal Bot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: Colors.teal,
          useMaterial3: true,
          brightness: Brightness.dark),
      themeMode: ThemeMode.system,
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Map<String, dynamic>? data;
  String? error;
  bool loading = false;
  String filter = 'All';
  Timer? timer;
  Timer? marketTimer;
  String marketSymbol = 'BTC';
  String marketInterval = '1m';
  String marketSignalFilter = 'All';
  String marketAdxOrder = 'Highest to lowest';
  String marketScanUniverse = 'All markets';
  bool marketLoading = false;
  String? marketError;
  DateTime? marketUpdated;
  final Map<String, List<Candle>> candles = {};
  final Map<String, double> latestPrices = {};
  Map<String, Analysis?> mtf = {};
  bool mtfBusy = false;
  Timer? mtfTimer;
  String tfFilter = 'All';
  List<PriceAlert> alerts = [];
  bool alertBusy = false;
  final Map<String, DateTime> alertChecked = {};
  Timer? alertTimer;
  List<NewsItem> news = [];
  List<EconEvent> events = [];
  Map<String, dynamic>? fng;
  bool newsBusy = false;
  String? newsError;
  DateTime? newsUpdated;
  String newsFilter = 'All';
  Map<String, double> futMeta = {};
  String futMetaSym = '';
  Timer? newsTimer;
  String? futuresError;
  List<ScanRow> scanRows = [];
  List<Map<String, dynamic>> movers = [];
  bool scanning = false, autoScan = false;
  double scanProgress = 0;
  String scanTf = '1h', scanFilter = 'All', scanSort = 'Strength';
  int scanN = 50;
  String? scanError;
  DateTime? scanUpdated;
  Timer? scanTimer;
  List<AppTrade> trades = [];
  bool autoPaper = false, paperBusy = false;
  double paperMinScore = 0.50;
  int paperMaxOpen = 8, paperMinQ = 4, paperRejected = 0, paperCoins = 20, paperMinAdx = 25;
  Set<String> paperTfs = {'5m', '1h', '4h'};
  bool paperScanBusy = false;
  final Map<String, int> paperLogged = {};     // coin|tf -> candle close already handled
  List<String> paperCoinList = [];
  DateTime paperCoinsAt = DateTime(2000);
  String paperStatus = '';
  final Map<String, Analysis?> _htfCache = {};
  DateTime _htfCacheAt = DateTime(2000);
  Timer? paperTimer;
  bool paperLoaded = false;
  // Signal Lab
  List<LabSnap> labPending = [], labRows = [];
  Map<String, List<double>> labAgg = {};
  Map<String, int> labLogged = {};
  bool labOn = false, labBusy = false, labLoaded = false, lab5m = false;
  int labCoins = 20, labScored = 0;
  String labStyle = 'All', labCat = 'All', labStatus = '';
  DateTime? labUpdated;
  Timer? labTimer;

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 30), (_) => load(silent: true));
    loadMarket();
    marketTimer = Timer.periodic(const Duration(seconds: 1), (_) => loadMarket(silent: true));
    loadFutures();
    loadAlerts();
    initNotifications();
    alertTimer = Timer.periodic(const Duration(seconds: 5), (_) => checkAlerts());
    loadNews();
    newsTimer = Timer.periodic(const Duration(minutes: 5), (_) => loadNews());
    loadMtf();
    mtfTimer = Timer.periodic(const Duration(seconds: 30), (_) => loadMtf());
    loadPaper();
    paperTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      checkPaper();
      paperScanCycle();
    });
    loadLab();
    labTimer = Timer.periodic(const Duration(seconds: 60), (_) => labCycle());
  }

  @override
  void dispose() {
    timer?.cancel();
    marketTimer?.cancel();
    mtfTimer?.cancel();
    scanTimer?.cancel();
    newsTimer?.cancel();
    alertTimer?.cancel();
    paperTimer?.cancel();
    labTimer?.cancel();
    super.dispose();
  }

  bool marketBusy = false;

  Future<void> loadMarket({bool silent = false}) async {
    if (marketBusy) return;                       // never overlap requests
    if (silent && yahooPairs.containsKey(marketSymbol) && marketUpdated != null &&
        DateTime.now().difference(marketUpdated!).inSeconds < 15) {
      return;                                     // Yahoo rate-limits: forex, gold and oil refresh every 15s
    }
    marketBusy = true;
    final sym = marketSymbol, tf = marketInterval;
    if (!silent && mounted) setState(() { marketLoading = true; marketError = null; });
    try {
      final list = await fetchCandles(sym, tf);
      candles['$sym|$tf'] = list;
      if (list.isNotEmpty) latestPrices[sym] = list.last.close;
      marketUpdated = DateTime.now();
      marketError = null;
    } catch (e) {
      marketError = '$e';
    } finally {
      marketBusy = false;
      if (mounted) setState(() => marketLoading = false);
    }
  }

  Future<void> loadFutures() async {
    try {
      final r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/exchangeInfo')).timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
      final syms = jsonDecode(r.body)['symbols'] as List;
      final m = <String, String>{};
      for (final x in syms) {
        if (x['contractType'] == 'PERPETUAL' && x['quoteAsset'] == 'USDT' && x['status'] == 'TRADING') {
          m['${x['baseAsset']}'] = '${x['symbol']}';
        }
      }
      futSymbols
        ..clear()
        ..addAll(m);
      futuresError = null;
    } catch (e) {
      futuresError = 'Could not load the Binance futures coin list ($e). Binance may be blocked on your network.';
    }
    if (mounted) setState(() {});
  }

  Future<List<Map<String, dynamic>>> fetchTickers() async {
    final r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/ticker/24hr')).timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) throw 'Binance futures unavailable (HTTP ${r.statusCode}).';
    final base = {for (final e in futSymbols.entries) e.value: e.key};
    final out = <Map<String, dynamic>>[];
    for (final t in jsonDecode(r.body) as List) {
      final coin = base['${t['symbol']}'];
      if (coin == null) continue;
      out.add({
        'coin': coin,
        'price': double.tryParse('${t['lastPrice']}') ?? 0.0,
        'chg': double.tryParse('${t['priceChangePercent']}') ?? 0.0,
        'vol': double.tryParse('${t['quoteVolume']}') ?? 0.0,
      });
    }
    out.sort((a, b) => (b['vol'] as double).compareTo(a['vol'] as double));
    return out;
  }

  void setAutoScan(bool v) {
    setState(() => autoScan = v);
    scanTimer?.cancel();
    if (v) {
      runScan();
      scanTimer = Timer.periodic(const Duration(seconds: 60), (_) => runScan());
    }
  }

  // ---------- Signal Lab ----------
  List<String> get labTfs => [if (lab5m) '5m', '15m', '1h', '4h', '1d'];

  Future<void> loadLab() async {
    try {
      final raw = await readStore('lab.json');
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        labOn = j['on'] == true;
        lab5m = j['m5'] == true;
        labCoins = (j['coins'] as num?)?.toInt() ?? 20;
        labScored = (j['scored'] as num?)?.toInt() ?? 0;
        labAgg = {for (final e in (j['agg'] as Map).entries) '${e.key}': (e.value as List).map((x) => (x as num).toDouble()).toList()};
        labPending = (j['pending'] as List).map((e) => LabSnap.fromJson(Map<String, dynamic>.from(e as Map))).toList();
        labRows = (j['rows'] as List).map((e) => LabSnap.fromJson(Map<String, dynamic>.from(e as Map))).toList();
        labLogged = {for (final e in (j['logged'] as Map).entries) '${e.key}': (e.value as num).toInt()};
      }
      labLoaded = true;
    } catch (_) {
      final raw = await readStore('lab.json');
      if (raw != null) await writeStore('lab_unreadable_backup.json', raw);
      labStatus = 'Saved lab data could not be read. A backup copy was kept and collecting is paused.';
    }
    if (mounted) setState(() {});
    if (labOn && labLoaded) labCycle();
  }

  Future<void> saveLab() async {
    if (!labLoaded) return;
    if (labRows.length > 1500) labRows = labRows.sublist(labRows.length - 1500);
    if (labPending.length > 4000) labPending = labPending.sublist(labPending.length - 4000);
    await writeStore('lab.json', jsonEncode({
      'on': labOn, 'm5': lab5m, 'coins': labCoins, 'scored': labScored, 'agg': labAgg,
      'pending': labPending.map((e) => e.toJson()).toList(), 'rows': labRows.map((e) => e.toJson()).toList(), 'logged': labLogged,
    }));
  }

  Future<void> setLabOn(bool v) async {
    setState(() => labOn = v);
    await saveLab();
    if (v) labCycle();
  }

  Future<void> labCycle() async {
    if (!labOn || labBusy || !labLoaded) return;
    labBusy = true;
    if (mounted) setState(() => labStatus = 'Working...');
    try {
      if (futSymbols.isEmpty) await loadFutures();
      var coins = movers.map((m) => '${m['coin']}').take(labCoins).toList();
      if (coins.isEmpty && futSymbols.isNotEmpty) {
        movers = await fetchTickers();
        coins = movers.map((m) => '${m['coin']}').take(labCoins).toList();
      }
      if (coins.isEmpty) throw futuresError ?? 'No coin list yet';
      if (!coins.contains('BTC')) coins.insert(0, 'BTC');
      final now = DateTime.now();

      // 1) score signals whose horizon has passed
      final due = <String, List<LabSnap>>{};
      for (final sn in labPending) {
        if (now.isAfter(sn.t0.add(Duration(milliseconds: barMs(sn.tf) * labHorizonBars)))) {
          due.putIfAbsent('${sn.coin}|${sn.tf}', () => []).add(sn);
        }
      }
      final done = <LabSnap>{};
      final keys = due.keys.toList();
      for (var i = 0; i < keys.length; i += 6) {
        await Future.wait(keys.skip(i).take(6).map((k) async {
          final parts = k.split('|');
          try {
            final cs = await fetchCandles(parts[0], parts[1]);
            for (final sn in due[k]!) {
              final r = evalSnap(sn, cs);
              if (r == 1) {
                labAdd(labAgg, sn);
                labRows.add(sn);
                labScored++;
                done.add(sn);
              } else if (r == 2) {
                done.add(sn);
              }
            }
          } catch (_) {}
        }));
      }
      labPending.removeWhere(done.contains);

      // 2) log a snapshot of every indicator for each coin and timeframe whose newest candle just closed
      final jobs = <List<String>>[];
      for (final c in coins) {
        for (final tf in labTfs) {
          final last = labLogged['$c|$tf'];
          if (last != null && now.millisecondsSinceEpoch < last + barMs(tf)) continue;
          jobs.add([c, tf]);
        }
      }
      var added = 0;
      for (var i = 0; i < jobs.length; i += 6) {
        final res = await Future.wait(jobs.skip(i).take(6).map<Future<LabSnap?>>((j) async {
          try {
            final cs = await fetchCandles(j[0], j[1]);
            if (cs.length < 61) return null;
            final closed = cs.sublist(0, cs.length - 1);
            final t0 = closed.last.time.add(Duration(milliseconds: barMs(j[1])));
            if (labLogged['${j[0]}|${j[1]}'] == t0.millisecondsSinceEpoch) return null;
            final a = analyze(closed, 2);
            if (a.atr.isNaN || a.atr <= 0) return null;
            final votes = <String, int>{};
            for (final r in [...a.ma, ...a.osc]) {
              if (r.sig != 0) votes[r.name] = r.sig;
            }
            if (a.side != 0) votes['OVERALL verdict'] = a.side;
            if (a.score.abs() >= .5) votes['OVERALL strong verdict'] = a.side;
            return LabSnap(j[0], j[1], t0, closed.last.close, a.atr, votes)..move = t0.millisecondsSinceEpoch.toDouble();
          } catch (_) {
            return null;
          }
        }));
        for (final sn in res.whereType<LabSnap>()) {
          labLogged['${sn.coin}|${sn.tf}'] = sn.move.toInt();     // temporarily carried the candle time here
          sn.move = 0;
          labPending.add(sn);
          added++;
        }
      }
      labUpdated = DateTime.now();
      labStatus = 'Last run: logged $added new signal sets, ${labPending.length} waiting to be scored, $labScored scored in total.';
      await saveLab();
    } catch (e) {
      labStatus = 'Lab could not run: $e';
    } finally {
      labBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> shareLabAcc() async {
    if (labAgg.isEmpty) return toast('Nothing scored yet. The first results appear about ${labHorizonBars} candles after the first signals.');
    final f = await _writeTemp('lab_indicator_accuracy.csv', labAggCsv(labAgg));
    if (f != null) await Share.shareXFiles([XFile(f.path, mimeType: 'text/csv')], subject: 'Indicator accuracy');
  }

  Future<void> shareLabRows() async {
    if (labRows.isEmpty) return toast('Nothing scored yet.');
    final f = await _writeTemp('lab_signal_snapshots.csv', labRowsCsv(labRows));
    if (f != null) await Share.shareXFiles([XFile(f.path, mimeType: 'text/csv')], subject: 'Signal snapshots');
  }

  Future<void> resetLab() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset the Lab?'),
        content: const Text('Deletes all collected and scored indicator data.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok == true) {
      labPending = [];
      labRows = [];
      labAgg = {};
      labLogged = {};
      labScored = 0;
      await saveLab();
      if (mounted) setState(() {});
    }
  }

  // ---------- in-app paper trading ----------
  Future<void> loadPaper() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = await readStore('paper.json') ?? p.getString('app_paper');
      if (raw != null) {
        try {
          trades = (jsonDecode(raw) as List).map((e) => AppTrade.fromJson(Map<String, dynamic>.from(e as Map))).toList();
        } catch (_) {
          await writeStore('paper_unreadable_backup.json', raw);      // never overwrite data we could not read
          toast('Saved paper trades could not be read. A backup copy was kept and saving is paused.');
          if (mounted) setState(() {});
          return;
        }
      }
      autoPaper = p.getBool('app_paper_auto') ?? false;
      paperMinScore = p.getDouble('app_paper_min') ?? 0.50;
      paperMaxOpen = p.getInt('app_paper_max') ?? 8;
      paperCoins = p.getInt('app_paper_coins') ?? 20;
      final tl = p.getStringList('app_paper_tfs');
      if (tl != null && tl.isNotEmpty) paperTfs = tl.toSet();
      paperMinQ = p.getInt('app_paper_q') ?? 4;
      paperMinAdx = p.getInt('app_paper_adx') ?? 25;
      if (!(p.getBool('app_paper_v3') ?? false)) {
        // Conservative migration based on the supplied paper-trade CSV: pause 15m/30m/1d
        // auto entries until they are independently validated; manual scanning remains available.
        paperTfs.remove('15m');
        paperTfs.remove('30m');
        paperTfs.remove('1d');
        if (paperTfs.isEmpty) paperTfs = {'5m', '1h', '4h'};
        paperMinScore = 0.50;
        paperMaxOpen = 8;
        paperCoins = 20;
        paperMinQ = 4;
        await p.setBool('app_paper_v3', true);
        await p.setDouble('app_paper_min', paperMinScore);
        await p.setInt('app_paper_max', paperMaxOpen);
        await p.setInt('app_paper_coins', paperCoins);
        await p.setInt('app_paper_q', paperMinQ);
        await p.setStringList('app_paper_tfs', paperTfs.toList());
      }
    } catch (_) {}
    paperLoaded = true;
    if (mounted) setState(() {});
    checkPaper();
    paperScanCycle();                 // catches up on candles that formed while the app was closed
  }

  Future<void> savePaper() async {
    if (!paperLoaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      if (trades.length > 5000) trades = trades.sublist(trades.length - 5000);
      final ok = await writeStore('paper.json', jsonEncode(trades.map((t) => t.toJson()).toList()));
      if (!ok) await p.setString('app_paper', jsonEncode(trades.map((t) => t.toJson()).toList()));
      await p.setBool('app_paper_auto', autoPaper);
      await p.setDouble('app_paper_min', paperMinScore);
      await p.setInt('app_paper_max', paperMaxOpen);
      await p.setInt('app_paper_q', paperMinQ);
      await p.setInt('app_paper_adx', paperMinAdx);
      await p.setInt('app_paper_coins', paperCoins);
      await p.setStringList('app_paper_tfs', paperTfs.toList());
    } catch (_) {}
  }

  double get paperEquity => paperStart + trades.where((t) => !t.isOpen).fold(0.0, (a, t) => a + t.pnl);

  AppTrade? openPaperTrade(String coin, String tf, Analysis a, String source, [Map<String, dynamic>? q]) {
    if (a.side == 0 || a.atr.isNaN || a.atr <= 0) return null;
    final plan = tradePlan(a);
    if (plan[2] < 1.2) return null;
    if (a.atr / a.last * 100 > 8 || plan[0] <= 0 || plan[1] <= 0) return null;   // illiquid coins with absurd stops, or a target below zero
    if (trades.any((t) => t.isOpen && t.coin == coin && t.tf == tf)) return null;
    final id = trades.isEmpty ? 1 : trades.map((t) => t.id).reduce(math.max) + 1;
    final t = AppTrade(
      id: id, coin: coin, tf: tf, source: source, verdict: a.verdict, side: a.side, buys: a.buys, sells: a.sells,
      neutrals: a.neutrals, mood: news.isEmpty ? 0 : newsScore(coin), entry: a.last, sl: plan[0], tp: plan[1],
      score: a.score, riskCash: paperEquity * paperRisk, adx: cleanNum(a.adx),
      atrPct: a.last == 0 ? null : cleanNum(a.atr / a.last * 100), opened: DateTime.now(),
      rvol: q?['rvol'] as double?, ext: q?['ext'] as double?, quality: (q?['q'] as int?) ?? 0,
      htfAgree: (q?['htf'] as int?) ?? 0, btc: (q?['btc'] as int?) ?? 0,
    );
    trades.add(t);
    return t;
  }

  // Cached analysis of a coin on a timeframe, closed candles only (the forming candle repaints), 3 minute cache.
  Future<Analysis?> _closedAnalysis(String coin, String tf) async {
    if (DateTime.now().difference(_htfCacheAt).inMinutes >= 3) {
      _htfCache.clear();
      _htfCacheAt = DateTime.now();
    }
    final key = '$coin|$tf';
    if (_htfCache.containsKey(key)) return _htfCache[key];
    Analysis? a;
    try {
      final cs = await fetchCandles(coin, tf);
      if (cs.length >= 60) a = analyze(cs.sublist(0, cs.length - 1), 2);
    } catch (_) {}
    _htfCache[key] = a;
    return a;
  }

  /// Confluence gate. Hard vetoes reject the setup, then 5 quality points decide. Returns null on a data failure.
  /// cs = candles including the forming one, ac = analysis of the closed candles only.
  Future<Map<String, dynamic>?> qualify(String coin, String tf, List<Candle> cs, Analysis ac) async {
    final side = ac.side;
    final closed = cs.sublist(0, cs.length - 1);
    String? veto;
    // overextension and exhaustion
    final c = closed.map((x) => x.close).toList();
    final ema20 = emaSeries(c, 20).last;
    final ext = ac.atr > 0 ? (c.last - ema20) * side / ac.atr : 0.0;        // + = stretched in trade direction
    if (ext > 1.5) veto = 'price stretched ${ext.toStringAsFixed(1)} ATR from EMA20 (chasing; max 1.5 ATR)';
    final rsi = rsiLast(c, 14);
    if (veto == null && !rsi.isNaN && ((side == 1 && rsi > 70) || (side == -1 && rsi < 30))) veto = 'RSI exhausted (${rsi.toStringAsFixed(0)})';
    // relative volume of the last closed candle vs the previous 20
    double? rvol;
    final vols = closed.map((x) => x.volume).toList();
    if (vols.length > 22 && vols.skip(vols.length - 21).fold<double>(0, (a, b) => a + b) > 0) {
      final avg = vols.sublist(vols.length - 21, vols.length - 1).fold<double>(0, (a, b) => a + b) / 20;
      rvol = avg > 0 ? vols.last / avg : null;
    }
    if (veto == null && rvol != null && rvol < 0.7) veto = 'dead volume (${rvol.toStringAsFixed(2)}x average)';
    if (veto == null && rvol != null && rvol > 3.0) veto = 'volume spike may be exhaustion (${rvol.toStringAsFixed(2)}x average)';
    // higher timeframes
    final idx = mtfList.indexOf(tf);
    int htfSide(Analysis? a) => a?.side ?? 0;
    final h1 = idx >= 0 && idx + 1 < mtfList.length ? await _closedAnalysis(coin, mtfList[idx + 1]) : null;
    final h2 = idx >= 0 && idx + 2 < mtfList.length ? await _closedAnalysis(coin, mtfList[idx + 2]) : null;
    if (veto == null && idx >= 0 && idx + 1 < mtfList.length && h1 == null) {
      veto = '${mtfList[idx + 1]} confirmation unavailable';
    }
    if (veto == null && idx >= 0 && idx + 1 < mtfList.length && htfSide(h1) != side) {
      veto = '${mtfList[idx + 1]} trend does not confirm it';
    }
    if (veto == null && idx >= 0 && idx + 2 < mtfList.length && h2 == null) {
      veto = '${mtfList[idx + 2]} confirmation unavailable';
    }
    if (veto == null && idx >= 0 && idx + 2 < mtfList.length && htfSide(h2) != side) {
      veto = '${mtfList[idx + 2]} trend does not confirm it';
    }
    // market regime: altcoins should not fight Bitcoin
    var btc = 0;
    if (!yahooPairs.containsKey(coin) && coin != 'BTC') {
      final b1 = await _closedAnalysis('BTC', '1h'), b4 = await _closedAnalysis('BTC', '4h');
      if (htfSide(b1) == htfSide(b4)) btc = htfSide(b1);
      if (veto == null && btc == -side) veto = 'Bitcoin trend is against it';
    }
    // crowding and news
    var crowdOk = true, crowdKnown = false;
    if (!yahooPairs.containsKey(coin)) {
      try {
        final fr = (await fetchFutMeta(coin))['funding'];
        if (fr != null) {
          crowdKnown = true;
          if ((side == 1 && fr > 0.05) || (side == -1 && fr < -0.05)) crowdOk = false;
        }
      } catch (_) {}
    }
    final ns = news.isEmpty ? 0 : newsScore(coin);
    if (news.isNotEmpty) {
      crowdKnown = true;
      if (ns * side <= -2) crowdOk = false;
    }
    var q = 0, htf = 0;
    if (h1 != null && htfSide(h1) == side) { q++; htf++; }
    if (h2 != null && htfSide(h2) == side) { q++; htf++; }
    if (rvol != null && rvol >= 1.2 && rvol <= 3.0) q++;
    if (!ac.adx.isNaN && ac.adx >= 20) q++;
    if (crowdKnown && crowdOk) q++;
    final why = veto ?? (q < paperMinQ ? 'quality $q of 5, needs $paperMinQ' : null);
    return {'ok': why == null, 'why': why, 'q': q, 'htf': htf, 'rvol': rvol, 'ext': ext, 'btc': btc};
  }

  /// Runs every minute. For each chosen timeframe whose candle just closed, checks the top coins once and opens paper trades.
  Future<void> paperScanCycle() async {
    if (!autoPaper || paperScanBusy || !paperLoaded) return;
    paperScanBusy = true;
    try {
      if (futSymbols.isEmpty) await loadFutures();
      if (paperCoinList.length < paperCoins || DateTime.now().difference(paperCoinsAt).inMinutes >= 30) {
        final t = await fetchTickers();
        movers = t;
        paperCoinList = t.map((m) => '${m['coin']}').toList();
        paperCoinsAt = DateTime.now();
      }
      final coins = paperCoinList.take(paperCoins).toList();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final jobs = <List<String>>[];
      for (final tf in mtfList) {
        if (!paperTfs.contains(tf)) continue;
        final bar = barMs(tf);
        final t0 = (nowMs ~/ bar) * bar;                 // when the newest candle closed
        if (nowMs - t0 > bar * 0.6) continue;            // too late, the entry would be stale
        for (final c in coins) {
          if (paperLogged['$c|$tf'] != t0) jobs.add([c, tf, '$t0']);
        }
      }
      if (jobs.isEmpty) return;
      if (mounted) setState(() => paperStatus = 'Checking ${jobs.length} coin/timeframe pairs...');
      final cands = <Map<String, dynamic>>[];
      for (var i = 0; i < jobs.length; i += 8) {
        final res = await Future.wait(jobs.skip(i).take(8).map<Future<Map<String, dynamic>?>>((j) async {
          try {
            final cs = await fetchCandles(j[0], j[1]);
            if (cs.length < 61) return null;
            final t0 = int.parse(j[2]);
            if (cs[cs.length - 2].time.millisecondsSinceEpoch + barMs(j[1]) != t0) return null;   // exchange has not published it yet, retry next minute
            paperLogged['${j[0]}|${j[1]}'] = t0;
            final ac = analyze(cs.sublist(0, cs.length - 1), 2);
            if (ac.side == 0 || ac.score.abs() < paperMinScore) return null;
            if (paperMinAdx > 0 && !ac.adx.isNaN && ac.adx < paperMinAdx) return null;   // no trend, no edge in the Lab
            return {'coin': j[0], 'tf': j[1], 'cs': cs, 'ac': ac};
          } catch (_) {
            return null;
          }
        }));
        cands.addAll(res.whereType<Map<String, dynamic>>());
        await Future.delayed(const Duration(milliseconds: 250));      // stay well inside the exchange rate limit
      }
      cands.sort((a, b) => (b['ac'] as Analysis).score.abs().compareTo((a['ac'] as Analysis).score.abs()));
      var opened = 0, rejected = 0, qchecked = 0;
      for (final m in cands) {
        if (trades.where((t) => t.isOpen).length >= paperMaxOpen) break;
        final coin = m['coin'] as String, tf = m['tf'] as String;
        final ac = m['ac'] as Analysis;
        final cs = m['cs'] as List<Candle>;
        if (trades.any((t) => t.isOpen && t.coin == coin)) continue; // avoid duplicate exposure across timeframes
        if (trades.where((t) => t.isOpen && t.side == ac.side).length >= 3) continue; // avoid crowded one-way exposure
        if (eventSoon(coin) != null) continue;                         // same news blackout as the Final call
        final holdH = paperHoldHours[tf] ?? 48;
        final cooldown = trades.any((t) => !t.isOpen && t.coin == coin && t.tf == tf && t.closed != null &&
            DateTime.now().difference(t.closed!).inMinutes < holdH * 15);   // wait a quarter of the hold time after a close
        if (cooldown) continue;
        // Use only the fully closed candle for the signal. Enter at the next candle's open
        // so the signal does not depend on a still-forming/repainting candle.
        final entryAnalysis = Analysis(
          ac.ma, ac.osc, ac.info, ac.buys, ac.sells, ac.neutrals,
          cs.last.open, ac.atr, ac.adx, ac.score, ac.sup, ac.res,
        );
        Map<String, dynamic>? q;
        if (paperMinQ > 0) {
          if (++qchecked > 40) break;                                  // keep each cycle fast
          q = await qualify(coin, tf, cs, ac);
          if (q == null) continue;
          if (q['ok'] != true) {
            rejected++;
            paperRejected++;
            continue;
          }
        }
        if (openPaperTrade(coin, tf, entryAnalysis, 'auto', q) != null) opened++;
      }
      if (opened > 0) await savePaper();
      paperStatus = 'Last check ${hhmm(DateTime.now())}: ${jobs.length} pairs, ${cands.length} signals, $opened opened, $rejected filtered out.';
    } catch (e) {
      paperStatus = 'Auto paper trading could not run: $e';
    } finally {
      paperScanBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> checkPaper() async {
    if (paperBusy) return;
    final open = trades.where((t) => t.isOpen).toList();
    if (open.isEmpty) return;
    paperBusy = true;
    try {
      final byCoin = <String, List<AppTrade>>{};
      for (final t in open) {
        byCoin.putIfAbsent(t.coin, () => []).add(t);
      }
      var closedNow = 0;
      final entries = byCoin.entries.toList();
      for (var i = 0; i < entries.length; i += 8) {
        await Future.wait(entries.skip(i).take(8).map((e) async {
          final oldest = e.value.map((t) => t.opened).reduce((a, b) => a.isBefore(b) ? a : b);
          final age = DateTime.now().difference(oldest);
          final tf = age.inHours < 20 ? '5m' : age.inDays < 10 ? '1h' : '4h';   // finest candles that still reach back to the entry
          try {
            final cs = await fetchCandles(e.key, tf);
            for (final t in e.value) {
              if (settleTrade(t, cs)) closedNow++;
            }
          } catch (_) {}
        }));
      }
      await savePaper();
      if (closedNow > 0) toast('$closedNow paper trade${closedNow == 1 ? '' : 's'} closed. See the Paper tab.');
    } finally {
      paperBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> setAutoPaper(bool v) async {
    setState(() => autoPaper = v);
    await savePaper();
    if (v) paperScanCycle();
  }

  Future<File?> _writeTemp(String name, String text) async {
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/$name');
      await f.writeAsString(text);
      return f;
    } catch (e) {
      toast('Could not create the file: $e');
      return null;
    }
  }

  Future<void> downloadCsv(String fileName, String contents) async {
    try {
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save CSV log',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['csv'],
        bytes: Uint8List.fromList(utf8.encode(contents)),
      );
      if (savedPath == null) {
        toast('Download cancelled.');
      } else {
        toast('CSV saved successfully.');
      }
    } catch (e) {
      toast('Could not save the CSV: $e');
    }
  }

  Future<void> downloadAppLog() async {
    if (trades.isEmpty) return toast('No in-app paper trades yet.');
    await downloadCsv('app_paper_trades.csv', tradesToCsv(trades));
  }

  Future<void> shareAppLog() async {
    if (trades.isEmpty) return toast('No in-app paper trades yet.');
    final f = await _writeTemp('app_paper_trades.csv', tradesToCsv(trades));
    if (f == null) return;
    try {
      await Share.shareXFiles([XFile(f.path, mimeType: 'text/csv')], subject: 'App paper trades log');
    } catch (e) {
      toast('Could not share the file: $e');
    }
  }

  Future<void> copyAppLog() async {
    if (trades.isEmpty) return toast('No in-app paper trades yet.');
    await Clipboard.setData(ClipboardData(text: tradesToCsv(trades)));
    toast('Copied ${trades.length} trades to the clipboard.');
  }

  Future<void> downloadAllLogs() async {
    var count = 0;
    if (trades.isNotEmpty) {
      await downloadCsv('app_paper_trades.csv', tradesToCsv(trades));
      count++;
    }
    final bot = await fetchPaperCsv();
    if (bot != null) {
      await downloadCsv('bot_paper_log.csv', bot);
      count++;
    }
    if (labAgg.isNotEmpty) {
      await downloadCsv('lab_indicator_accuracy.csv', labAggCsv(labAgg));
      count++;
      await downloadCsv('lab_signal_snapshots.csv', labRowsCsv(labRows));
      count++;
    }
    if (count == 0) toast('No logs are available to download yet.');
  }

  Future<void> shareBothLogs() async {
    final bot = await fetchPaperCsv();
    final files = <XFile>[];
    if (trades.isNotEmpty) {
      final f = await _writeTemp('app_paper_trades.csv', tradesToCsv(trades));
      if (f != null) files.add(XFile(f.path, mimeType: 'text/csv'));
    }
    if (bot != null) {
      final f = await _writeTemp('bot_paper_log.csv', bot);
      if (f != null) files.add(XFile(f.path, mimeType: 'text/csv'));
    }
    if (labAgg.isNotEmpty) {
      final a = await _writeTemp('lab_indicator_accuracy.csv', labAggCsv(labAgg));
      if (a != null) files.add(XFile(a.path, mimeType: 'text/csv'));
      final b = await _writeTemp('lab_signal_snapshots.csv', labRowsCsv(labRows));
      if (b != null) files.add(XFile(b.path, mimeType: 'text/csv'));
    }
    if (files.isEmpty) return toast('Nothing to share yet.');
    try {
      await Share.shareXFiles(files, subject: 'All logs (app paper trades, bot, Lab)');
    } catch (e) {
      toast('Could not share the files: $e');
    }
  }

  Future<void> resetPaper() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset in-app paper trading?'),
        content: const Text('This deletes every in-app paper trade and resets the account to \$10,000. Download the log first if you want to keep it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok == true) {
      trades = [];
      await savePaper();
      if (mounted) setState(() {});
    }
  }

  // Best and worst groups with at least 5 closed trades, to point at what to tune.
  List<String> paperInsights() {
    final closed = trades.where((t) => !t.isOpen).toList();
    if (closed.length < 10) return ['Collect at least 10 closed trades before reading anything into the numbers.'];
    final groups = <String, List<AppTrade>>{};
    void add(String k, AppTrade t) => groups.putIfAbsent(k, () => []).add(t);
    for (final t in closed) {
      add('timeframe ${t.tf}', t);
      add('${t.side == 1 ? 'BUY' : 'SELL'} trades', t);
      add(t.score.abs() >= .5 ? 'strong signals (score 0.5+)' : t.score.abs() >= .35 ? 'medium signals (0.35-0.5)' : 'weak signals (0.2-0.35)', t);
      add(t.adx == null ? 'ADX unknown' : t.adx! >= 25 ? 'trending (ADX 25+)' : t.adx! < 20 ? 'ranging (ADX under 20)' : 'moderate trend (ADX 20-25)', t);
      add(t.mood >= 2 ? 'bullish news' : t.mood <= -2 ? 'bearish news' : 'mixed news', t);
      add(t.quality == 0 ? 'unfiltered trades' : t.quality >= 4 ? 'quality 4-5' : 'quality 3', t);
    }
    final list = groups.entries.where((e) => e.value.length >= 5).map((e) => MapEntry(e.key, PStats(e.value))).toList()
      ..sort((a, b) => b.value.avgR.compareTo(a.value.avgR));
    if (list.length < 2) return ['Not enough trades per group yet (need 5+).'];
    String line(MapEntry<String, PStats> e) => '${e.key}: ${e.value.n} trades, ${e.value.winPct.toStringAsFixed(0)}% wins, ${e.value.avgR >= 0 ? '+' : ''}${e.value.avgR.toStringAsFixed(2)}R average';
    final out = <String>['Best: ${line(list.first)}', 'Worst: ${line(list.last)}'];
    final mfeLoss = closed.where((t) => t.reason == 'SL' && t.mfe >= 1).length;
    final slN = closed.where((t) => t.reason == 'SL').length;
    if (slN >= 5 && mfeLoss / slN >= .3) {
      out.add('${(100 * mfeLoss / slN).toStringAsFixed(0)}% of stopped trades first moved 1R in your favour. Taking partial profit earlier may help.');
    }
    return out;
  }

  Future<void> runScan() async {
    if (scanning) return;
    setState(() { scanning = true; scanError = null; scanProgress = 0; });
    try {
      final tickers = <Map<String, dynamic>>[];
      if (marketScanUniverse == 'Crypto' || marketScanUniverse == 'All markets') {
        if (futSymbols.isEmpty) await loadFutures();
        if (futSymbols.isNotEmpty) {
          final crypto = await fetchTickers();
          tickers.addAll(crypto.take(scanN));
          movers = crypto;
        } else if (marketScanUniverse == 'Crypto') {
          throw futuresError ?? 'No crypto futures loaded.';
        }
      }
      final nonCrypto = <String>[];
      if (marketScanUniverse == 'Forex') {
        nonCrypto.addAll(fxPairs);
      } else if (marketScanUniverse == 'Gold & commodities') {
        nonCrypto.addAll(commoditySymbols);
      } else if (marketScanUniverse == 'All markets') {
        nonCrypto.addAll(yahooPairs.keys);
      }
      for (final sym in nonCrypto) {
        tickers.add({'coin': sym, 'price': 0.0, 'chg': 0.0, 'vol': 0.0});
      }
      if (tickers.isEmpty) throw 'No instruments available for this market selection.';
      final top = tickers;
      final rows = <ScanRow>[];
      for (var i = 0; i < top.length; i += 6) {
        final batch = top.skip(i).take(6).toList();
        final res = await Future.wait(batch.map<Future<ScanRow?>>((t) async {
          try {
            final sym = t['coin'] as String;
            final cs = await fetchCandles(sym, scanTf);
            if (cs.length < 35) return null;
            return ScanRow(sym, cs.last.close, t['chg'] as double, t['vol'] as double, analyze(cs, decimalsFor(sym, cs.last.close)));
          } catch (_) {
            return null;
          }
        }));
        rows.addAll(res.whereType<ScanRow>());
        if (mounted) setState(() => scanProgress = math.min(1.0, (i + 6) / top.length));
      }
      scanRows = rows;
      scanUpdated = DateTime.now();
    } catch (e) {
      scanError = '$e';
    } finally {
      scanning = false;
      if (mounted) setState(() {});
    }
  }

  void openCoin(String coin, String tf, BuildContext ctx) {
    setState(() { marketSymbol = coin; marketInterval = tf; mtf = {}; });
    loadMarket();
    loadMtf();
    DefaultTabController.of(ctx).animateTo(0);
  }

  Future<void> pickCoin() async {
    if (futSymbols.isEmpty) await loadFutures();
    if (!mounted) return;
    final coins = futSymbols.keys.toList()..sort();
    var q = '';
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setM) {
        final shown = coins.where((c) => c.contains(q.toUpperCase())).toList();
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * .75,
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    autofocus: true,
                    decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'Search ${coins.length} Binance futures coins', border: const OutlineInputBorder()),
                    onChanged: (v) => setM(() => q = v),
                  ),
                ),
                Expanded(
                  child: coins.isEmpty
                      ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(futuresError ?? 'No coins loaded.')))
                      : ListView.builder(
                          itemCount: shown.length,
                          itemBuilder: (_, i) => ListTile(dense: true, title: Text(shown[i]), subtitle: Text(futSymbols[shown[i]] ?? ''), onTap: () => Navigator.pop(ctx, shown[i])),
                        ),
                ),
              ]),
            ),
          ),
        );
      }),
    );
    if (choice != null) {
      setState(() { marketSymbol = choice; mtf = {}; });
      loadMarket();
      loadMtf();
    }
  }

  Future<void> loadNews() async {
    if (newsBusy) return;
    newsBusy = true;
    try {
      final fn = fetchNews(), ff = fetchFng(), fe = fetchEvents();
      news = await fn;
      fng = await ff;
      events = await fe;
      newsError = news.isEmpty ? 'No headlines could be loaded. Check your internet connection.' : null;
      newsUpdated = DateTime.now();
    } catch (e) {
      newsError = '$e';
    } finally {
      newsBusy = false;
      if (mounted) setState(() {});
    }
  }

  // headlines from the last 24h that mention the symbol (full weight) or macro themes (half weight)
  int newsScore(String sym) {
    final keys = keysFor(sym);
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    var tot = 0.0;
    for (final n in news) {
      if (n.time != null && n.time!.isBefore(cutoff)) continue;
      final t = ' ${n.title.toLowerCase()} ';
      if (keys.any((k) => t.contains(k))) {
        tot += n.score;
      } else if (macroWords.any((k) => t.contains(k))) {
        tot += 0.5 * n.score;
      }
    }
    return tot.round();
  }

  bool newsMatches(NewsItem n, String sym) {
    final t = ' ${n.title.toLowerCase()} ';
    return keysFor(sym).any((k) => t.contains(k));
  }

  EconEvent? eventSoon(String sym) {
    final cur = symCurrencies[sym] ?? ['USD'];
    final now = DateTime.now();
    for (final e in events) {
      if (cur.contains(e.country) && e.time.difference(now).inMinutes.abs() <= 45) return e;
    }
    return null;
  }

  void toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> loadAlerts() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('alerts');
      if (raw != null) {
        alerts = (jsonDecode(raw) as List).map((e) => PriceAlert.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> saveAlerts() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('alerts', jsonEncode(alerts.map((a) => a.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> addAlert(String sym, double target, String note) async {
    final cur = latestPrices[sym] ?? await fetchPrice(sym);
    if (cur == null) {
      toast('Could not read the current $sym price. Try again in a moment.');
      return;
    }
    if ((target - cur).abs() < 1e-12) {
      toast('The target is the same as the current price.');
      return;
    }
    alerts.add(PriceAlert(DateTime.now().millisecondsSinceEpoch % 2000000000, sym, target, target > cur, note));
    await saveAlerts();
    if (mounted) setState(() {});
    toast('Alert set: $sym ${target > cur ? 'rises to' : 'falls to'} ${fmtPrice(target)}');
  }

  Future<void> checkAlerts() async {
    if (alertBusy) return;
    final active = alerts.where((a) => !a.done).toList();
    if (active.isEmpty) return;
    alertBusy = true;
    try {
      var changed = false;
      for (final sym in active.map((a) => a.sym).toSet()) {
        if (yahooPairs.containsKey(sym)) {
          final last = alertChecked[sym];
          if (last != null && DateTime.now().difference(last).inSeconds < 15) continue;
          alertChecked[sym] = DateTime.now();
        }
        final px = await fetchPrice(sym);
        if (px == null) continue;
        latestPrices[sym] = px;
        for (final a in active.where((x) => x.sym == sym)) {
          if ((a.above && px >= a.price) || (!a.above && px <= a.price)) {
            a.done = true;
            a.firedAt = DateTime.now();
            changed = true;
            final msg = '${a.sym} ${a.above ? 'rose to' : 'fell to'} ${fmtPrice(px)} (your alert ${fmtPrice(a.price)})${a.note.isEmpty ? '' : '. ${a.note}'}';
            await notify(a.id, 'Price alert: ${a.sym}', msg);
            HapticFeedback.heavyImpact();
            SystemSound.play(SystemSoundType.alert);
            toast(msg);
          }
        }
      }
      if (changed) {
        await saveAlerts();
      }
      if (mounted) setState(() {});
    } finally {
      alertBusy = false;
    }
  }

  Future<void> alertDialog({double? preset, String note = ''}) async {
    final cur = latestPrices[marketSymbol];
    final priceCtl = TextEditingController(text: preset != null ? fmtPrice(preset) : (cur == null ? '' : fmtPrice(cur)));
    final noteCtl = TextEditingController(text: note);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Price alert: $marketSymbol'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(cur == null ? 'Current price unavailable' : 'Current price ${fmtPrice(cur)}'),
          TextField(controller: priceCtl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Notify me when price reaches')),
          TextField(controller: noteCtl, decoration: const InputDecoration(labelText: 'Note (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Set alert')),
        ],
      ),
    );
    if (ok == true) {
      final v = double.tryParse(priceCtl.text.trim().replaceAll(',', '.'));
      if (v == null || v <= 0) {
        toast('Enter a valid price.');
      } else {
        await addAlert(marketSymbol, v, noteCtl.text.trim());
      }
    }
  }

  Future<void> loadMtf() async {
    if (mtfBusy) return;
    mtfBusy = true;
    final sym = marketSymbol;
    try {
      final res = await Future.wait(mtfList.map<Future<Analysis?>>((tf) async {
        try {
          final cs = await fetchCandles(sym, tf);
          return cs.length >= 35 ? analyze(cs, decimalsFor(sym, cs.last.close)) : null;
        } catch (_) {
          return null;
        }
      }));
      if (sym == marketSymbol) {
        mtf = {for (var i = 0; i < mtfList.length; i++) mtfList[i]: res[i]};
        if (!yahooPairs.containsKey(sym)) {
          final meta = await fetchFutMeta(sym);
          if (sym == marketSymbol) {
            futMeta = meta;
            futMetaSym = sym;
          }
        } else {
          futMeta = {};
          futMetaSym = '';
        }
      }
    } finally {
      mtfBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> load({bool silent = false}) async {
    if (feedUrl.isEmpty) {
      setState(() => error = 'FEED_URL was not set when the app was built.');
      return;
    }
    if (!silent) setState(() => loading = true);
    try {
      final r = await http
          .get(Uri.parse('$feedUrl?t=${DateTime.now().millisecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        throw 'Feed not found (HTTP ${r.statusCode}). Run the bot once and make sure the repo is public.';
      }
      data = jsonDecode(r.body) as Map<String, dynamic>;
      error = null;
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  Widget marketTab() {
    final all = candles['$marketSymbol|$marketInterval'] ?? <Candle>[];
    final list = all.takeLast(60);
    final an = all.length >= 35 ? analyze(all, decimalsFor(marketSymbol, all.last.close)) : null;
    final price = latestPrices[marketSymbol];
    final pkt = DateTime.now().toUtc().add(const Duration(hours: 5));
    String hm(int h, int m) => '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    final sessions = <Map<String, dynamic>>[
      {'name':'Tokyo', 'start':5*60, 'end':14*60},
      {'name':'London', 'start':13*60, 'end':22*60},
      {'name':'New York Forex', 'start':17*60, 'end':2*60},
      {'name':'US Stocks', 'start':18*60+30, 'end':1*60},
    ];
    final nowMin = pkt.hour*60 + pkt.minute;
    bool isOpen(Map<String,dynamic> x) { final a=x['start'] as int, b=x['end'] as int; return a < b ? nowMin >= a && nowMin < b : nowMin >= a || nowMin < b; }
    return RefreshIndicator(onRefresh: loadMarket, child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(12), children: [
      Wrap(spacing: 8, runSpacing: 4, children: [
        ActionChip(avatar: const Icon(Icons.add_alert, size: 18), label: const Text('Set price alert'), onPressed: () => alertDialog()),
        ActionChip(avatar: const Icon(Icons.search, size: 18), label: Text(futSymbols.isEmpty ? 'All futures coins' : 'All coins (${futSymbols.length})'), onPressed: pickCoin),
        for (final a in {...favorites, marketSymbol}) ChoiceChip(label: Text(a), selected: marketSymbol == a, onSelected: (_) { setState(() { marketSymbol = a; mtf = {}; }); loadMarket(); loadMtf(); }),
      ]),
      const SizedBox(height: 10),
      Wrap(spacing: 8, children: [for (final tf in tfList) ChoiceChip(label: Text(tf), selected: marketInterval==tf, onSelected: (_) { setState(() => marketInterval=tf); loadMarket(); })]),
      const SizedBox(height: 10),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(marketSymbol, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(price == null ? 'Price unavailable' : '${fxPairs.contains(marketSymbol) ? '' : '\$'}${price.toStringAsFixed(decimalsFor(marketSymbol, price))}', style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w700)),
        Text('Free public data • Last update: ${marketUpdated == null ? 'not yet' : ago(marketUpdated!.toIso8601String())}'),
        const SizedBox(height: 12),
        if (marketLoading) const LinearProgressIndicator(),
        if (marketError != null) Text(marketError!, style: const TextStyle(color: Colors.orange)),
        if (list.length > 1) SizedBox(height: 260, child: CustomPaint(painter: CandlePainter(list, Theme.of(context).brightness==Brightness.dark, an?.sup ?? const <double>[], an?.res ?? const <double>[]), child: const SizedBox.expand())) else const SizedBox(height: 200, child: Center(child: Text('Waiting for candlestick data...'))),
        const Text('Candles show open, high, low and close. Free APIs may delay or limit data.', style: TextStyle(fontSize: 11)),
        const SizedBox(height: 14),
        Text('Technical indicators', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (an != null) _indicatorPanel(an) else const Text('More candles are needed to calculate indicators.'),
      ]))),
      _mtfCard(),
      _marketSignalFilterCard(),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Market sessions • Pakistan time (UTC+5)', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final x in sessions) ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(x['name'] as String), subtitle: Text('${hm((x['start'] as int) ~/ 60, (x['start'] as int)%60)} – ${hm((x['end'] as int) ~/ 60, (x['end'] as int)%60)} PKT'), trailing: Text(isOpen(x) ? 'OPEN' : 'CLOSED', style: TextStyle(fontWeight: FontWeight.bold, color: isOpen(x) ? Colors.green : Colors.grey))),
        const Text('Indicative session hours only; holidays and daylight-saving changes may affect hours. Crypto trades 24/7.', style: TextStyle(fontSize: 11)),
      ]))),
    ]));
  }

  Future<void> _runMarketScan() async {
    final supported = {'5m', '15m', '30m', '1h', '4h', '1d'};
    final tf = supported.contains(marketInterval) ? marketInterval : '5m';
    setState(() {
      scanTf = tf;
      scanFilter = marketSignalFilter;
    });
    await runScan();
  }

  Widget _marketSignalFilterCard() {
    final rows = scanRows.where((r) {
      if (marketSignalFilter == 'BUY') return r.a.side == 1;
      if (marketSignalFilter == 'SELL') return r.a.side == -1;
      if (marketSignalFilter == 'NEUTRAL') return r.a.side == 0;
      if (marketSignalFilter == 'STRONG BUY') return r.a.verdict == 'STRONG BUY';
      if (marketSignalFilter == 'STRONG SELL') return r.a.verdict == 'STRONG SELL';
      return true;
    }).toList();
    rows.sort((a, b) => marketAdxOrder == 'Lowest to highest'
        ? a.a.adx.compareTo(b.a.adx)
        : b.a.adx.compareTo(a.a.adx));
    Color col(int side) => side == 1 ? Colors.green : side == -1 ? Colors.red : Colors.grey;
    return Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Market ADX & signal filters', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text('Scan crypto, major/cross forex pairs, precious metals, energy and agricultural commodities on the selected timeframe; sort by ADX and filter signals.', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final universe in ['All markets', 'Crypto', 'Forex', 'Gold & commodities'])
            ChoiceChip(label: Text(universe), selected: marketScanUniverse == universe, onSelected: (_) => setState(() => marketScanUniverse = universe)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final f in ['All', 'BUY', 'NEUTRAL', 'SELL', 'STRONG BUY', 'STRONG SELL'])
            ChoiceChip(label: Text(f), selected: marketSignalFilter == f, onSelected: (_) => setState(() => marketSignalFilter = f)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final order in ['Lowest to highest', 'Highest to lowest'])
            ChoiceChip(label: Text('ADX: $order'), selected: marketAdxOrder == order, onSelected: (_) => setState(() => marketAdxOrder = order)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          ElevatedButton.icon(
            onPressed: scanning ? null : _runMarketScan,
            icon: const Icon(Icons.radar),
            label: Text(scanning ? 'Scanning...' : 'Scan market'),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(scanUpdated == null ? 'No scan yet' : '${rows.length} results • $marketScanUniverse • ${scanTf} • ${ago(scanUpdated!.toIso8601String())}', style: const TextStyle(fontSize: 11))),
        ]),
        if (scanning) LinearProgressIndicator(value: scanProgress == 0 ? null : scanProgress),
        if (scanError != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(scanError!, style: const TextStyle(color: Colors.orange, fontSize: 12))),
        if (rows.isEmpty && !scanning)
          const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('No scan results yet. Tap Scan market to load ADX and signal values.', style: TextStyle(fontSize: 12)))
        else
          for (final r in rows.take(50))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              onTap: () => openCoin(r.coin, scanTf, context),
              title: Text('${r.coin}  •  ADX ${r.a.adx.toStringAsFixed(1)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('Buy ${r.a.buys} / Neutral ${r.a.neutrals} / Sell ${r.a.sells}'),
              trailing: Text(r.a.verdict, style: TextStyle(fontWeight: FontWeight.bold, color: col(r.a.side))),
            ),
        const Text('ADX measures trend strength, not direction. Signal filters are descriptive and do not guarantee profitable trades.', style: TextStyle(fontSize: 11)),
      ],
    )));
  }

  Widget _mtfCard() {
    Color col(int side) => side == 1 ? Colors.green : side == -1 ? Colors.red : Colors.grey;
    return Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Signals by timeframe', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      for (final tf in mtfList)
        Builder(builder: (_) {
          final a = mtf[tf];
          return ListTile(
            contentPadding: EdgeInsets.zero, dense: true,
            selected: marketInterval == tf,
            onTap: () { setState(() => marketInterval = tf); loadMarket(); },
            title: Text(tf, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(a == null ? (mtfBusy ? 'Loading...' : 'No data') : 'Buy ${a.buys} / Neutral ${a.neutrals} / Sell ${a.sells}'),
            trailing: Text(a == null ? '-' : a.verdict, style: TextStyle(fontWeight: FontWeight.bold, color: a == null ? Colors.grey : col(a.side))),
          );
        }),
      const Text('Tap a timeframe to open its chart. Updates every 30 seconds.', style: TextStyle(fontSize: 11)),
    ])));
  }

  Widget _section(String title, List<Reading> rows) {
    if (rows.isEmpty) return const SizedBox.shrink();
    Color? col(int s) => s == 1 ? Colors.green : s == -1 ? Colors.red : null;
    String lab(int s) => s == 1 ? 'BUY' : s == -1 ? 'SELL' : 'NEUTRAL';
    String tag(Reading r) => r.mr ? 'info only' : lab(r.sig);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 10, bottom: 2), child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
      for (final r in rows)
        _indicatorRow(r.name, title == 'Levels' ? r.value : '${r.value}  ${tag(r)}', r.mr ? null : col(r.sig)),
    ]);
  }

  Widget _finalCall(Analysis a) {
    final d = decimalsFor(marketSymbol, a.last);
    String f(double v) => v.toStringAsFixed(d);
    final side = a.side;
    final why = <String>[];
    var pts = 0;
    why.add(a.adx.isNaN
        ? '• Trend strength unknown'
        : a.adx > 25
            ? '• Strong trend (ADX ${a.adx.toStringAsFixed(0)}): trend indicators count more'
            : a.adx < 20
                ? '• Ranging market (ADX ${a.adx.toStringAsFixed(0)}): oscillators count more'
                : '• Moderate trend (ADX ${a.adx.toStringAsFixed(0)})');
    final idx = mtfList.indexOf(marketInterval);
    for (final tf in mtfList.skip(idx + 1).take(2)) {
      final h = mtf[tf];
      if (h == null) continue;
      if (side != 0 && h.side == side) {
        pts++;
        why.add('✔ $tf agrees (${h.verdict})');
      } else if (side != 0 && h.side == -side) {
        pts--;
        why.add('✖ $tf disagrees (${h.verdict})');
      } else {
        why.add('• $tf is ${h.verdict}');
      }
    }
    if (side != 0 && a.atr > 0) {
      final wall = side == 1 ? a.res : a.sup;
      final floor = side == 1 ? a.sup : a.res;
      if (wall.isNotEmpty && (wall.first - a.last).abs() / a.atr < 1.0) {
        pts--;
        why.add('✖ ${side == 1 ? 'Resistance' : 'Support'} ${f(wall.first)} is very close');
      }
      if (floor.isNotEmpty && (a.last - floor.first).abs() / a.atr < 0.8) {
        pts++;
        why.add('✔ Price is next to ${side == 1 ? 'support' : 'resistance'} ${f(floor.first)}');
      }
    }
    if (news.isNotEmpty) {
      final ns = newsScore(marketSymbol);
      if (ns >= 2) {
        if (side == 1) pts++;
        if (side == -1) pts--;
        why.add('${side == -1 ? '✖' : side == 1 ? '✔' : '•'} News is bullish (score $ns)');
      } else if (ns <= -2) {
        if (side == -1) pts++;
        if (side == 1) pts--;
        why.add('${side == 1 ? '✖' : side == -1 ? '✔' : '•'} News is bearish (score $ns)');
      } else {
        why.add('• News is mixed (score $ns)');
      }
    }
    if (futMetaSym == marketSymbol && futMeta.isNotEmpty) {
      final fr = futMeta['funding'];
      if (fr != null) {
        if (side == 1 && fr > 0.05) {
          pts--;
          why.add('✖ Funding ${fr.toStringAsFixed(3)}%: crowded longs');
        } else if (side == -1 && fr < -0.05) {
          pts--;
          why.add('✖ Funding ${fr.toStringAsFixed(3)}%: crowded shorts');
        } else {
          why.add('• Funding ${fr.toStringAsFixed(3)}%');
        }
      }
      if (futMeta['ls'] != null) why.add('• Long/short accounts ${futMeta['ls']!.toStringAsFixed(2)}');
      if (futMeta['oi'] != null) why.add('• Open interest ${compactNum(futMeta['oi']!)} coins');
    }
    final fg = fng;
    if (fg != null && !yahooPairs.containsKey(marketSymbol)) why.add('• Crypto Fear & Greed ${fg['value']} (${fg['label']})');
    final ev = eventSoon(marketSymbol);
    String call;
    Color col;
    if (ev != null) {
      call = 'WAIT: ${ev.country} ${ev.title} ${untilText(ev.time)}';
      col = Colors.orange;
    } else if (side == 0) {
      call = 'NEUTRAL: no clear edge';
      col = Colors.grey;
    } else {
      final conf = (a.score.abs() >= .5 && pts >= 1) || pts >= 2 ? 'HIGH' : pts >= 0 ? 'MEDIUM' : 'LOW';
      call = '${side == 1 ? 'BUY' : 'SELL'}: $conf confidence';
      col = side == 1 ? Colors.green : Colors.red;
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: col, width: 2), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Final call (indicators + timeframes + chart levels + news)', style: TextStyle(fontSize: 11)),
        Text(call, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: col)),
        const SizedBox(height: 4),
        for (final w in why) Text(w, style: const TextStyle(fontSize: 12)),
      ]),
    );
  }

  Widget _indicatorPanel(Analysis a) {
    final d = decimalsFor(marketSymbol, a.last);
    final col = a.side == 1 ? Colors.green : a.side == -1 ? Colors.red : Colors.grey;
    String f(double v) => v.isNaN || v.isInfinite ? 'N/A' : v.toStringAsFixed(d);
    String plan;
    List<double>? tpl;
    var tp1 = 0.0;
    if (a.side == 0 || a.atr.isNaN) {
      plan = 'No clear trade: indicators are mixed';
    } else {
      tpl = tradePlan(a);
      tp1 = a.last + a.side * (a.last - tpl[0]).abs();
      plan = '${a.side == 1 ? 'BUY' : 'SELL'} ${f(a.last)} | SL ${f(tpl[0])} | TP1 ${f(tp1)} (1R) | TP2 ${f(tpl[1])} | R:R 1:${tpl[2].toStringAsFixed(1)}';
    }
    final plan2 = tpl;
    final dirName = a.side == 1 ? 'BUY' : 'SELL';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _finalCall(a),
      if (plan2 != null)
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(onPressed: () => addAlert(marketSymbol, tp1, '$dirName plan: TP1 reached'), icon: const Icon(Icons.add_alert, size: 16), label: const Text('Alert TP1')),
          OutlinedButton.icon(onPressed: () => addAlert(marketSymbol, plan2[1], '$dirName plan: TP2 reached'), icon: const Icon(Icons.add_alert, size: 16), label: const Text('Alert TP2')),
          OutlinedButton.icon(onPressed: () => addAlert(marketSymbol, plan2[0], '$dirName plan: stop loss hit'), icon: const Icon(Icons.add_alert, size: 16), label: const Text('Alert SL')),
        ]),
      if (plan2 != null)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () async {
              final t = openPaperTrade(marketSymbol, marketInterval, a, 'manual');
              if (t == null) return toast('Not opened: needs a clear signal, 1.2+ reward to risk and no open trade on this coin.');
              await savePaper();
              if (mounted) setState(() {});
              toast('Paper trade opened: ${t.coin} ${t.side == 1 ? 'BUY' : 'SELL'} at ${fmtPrice(t.entry)}. Track it in the Paper tab.');
            },
            icon: const Icon(Icons.science, size: 16),
            label: const Text('Paper trade this'),
          ),
        ),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(border: Border.all(color: col), borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$marketInterval: ${a.verdict}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: col)),
          Text('Buy ${a.buys}  Neutral ${a.neutrals}  Sell ${a.sells}  (${a.total} indicators)'),
          const SizedBox(height: 4),
          Text(plan, style: TextStyle(fontWeight: FontWeight.w600, color: a.side == 0 ? null : col)),
        ]),
      ),
      _section('Moving averages and trend', a.ma),
      _section('Oscillators and momentum', a.osc),
      _section('Levels', a.info),
      const Padding(padding: EdgeInsets.only(top: 8), child: Text('Calculated from the last 300 candles. Support and resistance are swing levels read from the chart (green and red dashed lines). Stop and target use those levels when they are close, otherwise 1.5x ATR and 2x risk. Not a guaranteed signal. Gold, forex and oil are closed on weekends. Forex has no real volume, so volume indicators (VWAP, MFI, OBV) only appear for crypto, gold and oil.', style: TextStyle(fontSize: 11))),
    ]);
  }

  Widget _indicatorRow(String name, String value, Color? color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(child: Text(name)),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: TextStyle(fontWeight: FontWeight.w600, color: color),
              ),
            ),
          ],
        ),
      );

  Widget wrap(List<Widget> children) {
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: children,
      ),
    );
  }

  Widget message(String text) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center),
      );

  Widget scannerTab() {
    final rows = scanRows.where((r) => scanFilter == 'All' || (scanFilter == 'BUY' && r.a.side == 1) || (scanFilter == 'SELL' && r.a.side == -1) || (scanFilter == 'NEUTRAL' && r.a.side == 0) || r.a.verdict == scanFilter).toList();
    if (scanSort == 'Strength') {
      rows.sort((a, b) => b.a.score.abs().compareTo(a.a.score.abs()));
    } else if (scanSort == '24h %') {
      rows.sort((a, b) => b.change.abs().compareTo(a.change.abs()));
    } else {
      rows.sort((a, b) => b.volume.compareTo(a.volume));
    }
    final gain = [...movers]..sort((a, b) => (b['chg'] as double).compareTo(a['chg'] as double));
    final lose = [...movers]..sort((a, b) => (a['chg'] as double).compareTo(b['chg'] as double));
    Color col(int side) => side == 1 ? Colors.green : side == -1 ? Colors.red : Colors.grey;
    return Builder(builder: (ctx) {
      return RefreshIndicator(
        onRefresh: runScan,
        child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(12), children: [
          Text('Binance Futures scanner', style: Theme.of(ctx).textTheme.titleMedium),
          Text(futSymbols.isEmpty ? (futuresError ?? 'Loading the coin list...') : '${futSymbols.length} USDT perpetual coins. Scans the most active ones with all indicators.', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [for (final t in ['5m', '15m', '30m', '1h', '4h', '1d']) ChoiceChip(label: Text(t), selected: scanTf == t, onSelected: (_) => setState(() => scanTf = t))]),
          Wrap(spacing: 8, children: [
            for (final n in [20, 50, 100, 999]) ChoiceChip(label: Text(n == 999 ? 'All coins' : 'Top $n'), selected: scanN == n, onSelected: (_) => setState(() => scanN = n)),
          ]),
          Wrap(spacing: 8, children: [for (final f in ['All', 'BUY', 'NEUTRAL', 'SELL', 'STRONG BUY', 'STRONG SELL']) ChoiceChip(label: Text(f), selected: scanFilter == f, onSelected: (_) => setState(() => scanFilter = f))]),
          Wrap(spacing: 8, children: [for (final f in ['Strength', '24h %', 'Volume']) ChoiceChip(label: Text('Sort: $f'), selected: scanSort == f, onSelected: (_) => setState(() => scanSort = f))]),
          Row(children: [
            ElevatedButton.icon(onPressed: scanning ? null : runScan, icon: const Icon(Icons.radar), label: Text(scanning ? 'Scanning...' : 'Scan now')),
            const SizedBox(width: 12),
            const Text('Auto 60s'),
            Switch(value: autoScan, onChanged: setAutoScan),
          ]),
          if (scanning) LinearProgressIndicator(value: scanProgress == 0 ? null : scanProgress),
          if (scanError != null) Padding(padding: const EdgeInsets.all(8), child: Text(scanError!, style: const TextStyle(color: Colors.orange))),
          if (scanUpdated != null) Text('Scanned ${rows.length} coins on $scanTf, ${ago(scanUpdated!.toIso8601String())}', style: const TextStyle(fontSize: 12)),
          if (movers.isNotEmpty)
            Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('24h movers (all ${movers.length} coins)', style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final m in gain.take(6)) ActionChip(label: Text('${m['coin']} +${(m['chg'] as double).toStringAsFixed(1)}%', style: const TextStyle(color: Colors.green)), onPressed: () => openCoin('${m['coin']}', scanTf, ctx)),
              ]),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final m in lose.take(6)) ActionChip(label: Text('${m['coin']} ${(m['chg'] as double).toStringAsFixed(1)}%', style: const TextStyle(color: Colors.red)), onPressed: () => openCoin('${m['coin']}', scanTf, ctx)),
              ]),
            ]))),
          if (scanRows.isEmpty && !scanning) const Padding(padding: EdgeInsets.all(24), child: Text('Tap Scan now to check every coin on the timeframe you picked.', textAlign: TextAlign.center)),
          for (final r in rows)
            ListTile(
              dense: true,
              onTap: () => openCoin(r.coin, scanTf, ctx),
              title: Text('${r.coin}   ${fmtPrice(r.price)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('24h ${r.change >= 0 ? '+' : ''}${r.change.toStringAsFixed(1)}%  |  Buy ${r.a.buys} / Neutral ${r.a.neutrals} / Sell ${r.a.sells}'),
              trailing: Text(r.a.verdict, style: TextStyle(fontWeight: FontWeight.bold, color: col(r.a.side))),
            ),
          const Padding(padding: EdgeInsets.only(top: 8), child: Text('Verdicts come from about 45 indicators on the loaded candles. Not a guaranteed signal. Tap a coin to open its chart.', style: TextStyle(fontSize: 11))),
        ]),
      );
    });
  }

  Widget newsTab() {
    final shown = news.where((n) {
      if (newsFilter == 'Bullish') return n.score > 0;
      if (newsFilter == 'Bearish') return n.score < 0;
      if (newsFilter.startsWith('Selected')) return newsMatches(n, marketSymbol);
      return true;
    }).take(60).toList();
    final now = DateTime.now();
    final upcoming = events.where((e) => e.time.isAfter(now.subtract(const Duration(hours: 2)))).take(10).toList();
    final fg = fng;
    Color fgColor(int v) => v < 25 ? Colors.red : v < 45 ? Colors.orange : v < 55 ? Colors.grey : v < 75 ? Colors.lightGreen : Colors.green;
    return RefreshIndicator(
      onRefresh: loadNews,
      child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(12), children: [
        Text('News and market data', style: Theme.of(context).textTheme.titleMedium),
        Text(newsUpdated == null ? 'Loading...' : 'Updated ${ago(newsUpdated!.toIso8601String())}. Sources: CoinDesk, Cointelegraph, Decrypt, FXStreet, ForexLive, CNBC, BBC Business.', style: const TextStyle(fontSize: 12)),
        if (fg != null)
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Crypto Fear & Greed: ${fg['value']} (${fg['label']})', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: (fg['value'] as int) / 100, color: fgColor(fg['value'] as int), minHeight: 8),
            if (fg['prev'] != null) Text('Yesterday: ${fg['prev']}', style: const TextStyle(fontSize: 12)),
          ]))),
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('High-impact economic events', style: TextStyle(fontWeight: FontWeight.w700)),
          if (upcoming.isEmpty) const Text('None found for this week (or the calendar could not load).', style: TextStyle(fontSize: 12)),
          for (final e in upcoming)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${e.country} ${e.title}  |  ${hhmm(e.time)} (${untilText(e.time)})${e.forecast.isNotEmpty ? '  fc ${e.forecast}' : ''}${e.previous.isNotEmpty ? '  prev ${e.previous}' : ''}', style: const TextStyle(fontSize: 12)),
            ),
          const SizedBox(height: 4),
          const Text('The Final call shows WAIT when an event for the pair is within 45 minutes.', style: TextStyle(fontSize: 11)),
        ]))),
        Wrap(spacing: 8, children: [
          for (final f in ['All', 'Selected: $marketSymbol', 'Bullish', 'Bearish'])
            ChoiceChip(label: Text(f), selected: newsFilter == f || (f.startsWith('Selected') && newsFilter.startsWith('Selected')), onSelected: (_) => setState(() => newsFilter = f)),
        ]),
        if (news.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(newsError ?? 'Loading news...')),
        for (final n in shown)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(n.score > 0 ? Icons.arrow_upward : n.score < 0 ? Icons.arrow_downward : Icons.remove, color: n.score > 0 ? Colors.green : n.score < 0 ? Colors.red : Colors.grey),
            title: Text(n.title, maxLines: 3, overflow: TextOverflow.ellipsis),
            subtitle: Text('${n.source}${n.time == null ? '' : '  |  ${ago(n.time!.toIso8601String())}'}'),
          ),
        const Padding(padding: EdgeInsets.only(top: 8), child: Text('Headline sentiment is a simple keyword count, so treat it as a hint, not a verdict.', style: TextStyle(fontSize: 11))),
      ]),
    );
  }

  Widget alertsTab() {
    final active = alerts.where((a) => !a.done).toList();
    final done = alerts.where((a) => a.done).toList().reversed.toList();
    String away(PriceAlert a) {
      final px = latestPrices[a.sym];
      if (px == null) return 'waiting for price';
      return '${((a.price - px) / px * 100).toStringAsFixed(2)}% away (now ${fmtPrice(px)})';
    }
    return ListView(padding: const EdgeInsets.all(12), children: [
      Text('Price alerts', style: Theme.of(context).textTheme.titleMedium),
      const Text('Pick a price and the app notifies you when it is reached. Prices are checked every 5 seconds (15 seconds for gold, forex and oil) while the app is running, including in the background for a while. Android can pause the app when it is fully closed or in battery saver, so keep it open for important levels. Allow notifications when asked, and exclude the app from battery optimization in Android settings.', style: TextStyle(fontSize: 12)),
      const SizedBox(height: 8),
      ElevatedButton.icon(onPressed: () => alertDialog(), icon: const Icon(Icons.add_alert), label: Text('New alert for $marketSymbol')),
      const Text('Change the coin in the Markets tab. In Markets you can also tap Alert TP1, TP2 or SL under the Final call.', style: TextStyle(fontSize: 11)),
      const SizedBox(height: 8),
      Text('Active (${active.length})', style: const TextStyle(fontWeight: FontWeight.w700)),
      if (active.isEmpty) const Text('No active alerts.'),
      for (final a in active)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(a.above ? Icons.trending_up : Icons.trending_down, color: a.above ? Colors.green : Colors.red),
          title: Text('${a.sym} ${a.above ? 'rises to' : 'falls to'} ${fmtPrice(a.price)}'),
          subtitle: Text('${away(a)}${a.note.isEmpty ? '' : '\n${a.note}'}'),
          trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { setState(() => alerts.remove(a)); saveAlerts(); }),
        ),
      const SizedBox(height: 8),
      Text('Triggered (${done.length})', style: const TextStyle(fontWeight: FontWeight.w700)),
      for (final a in done)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.check_circle, color: Colors.green),
          title: Text('${a.sym} ${a.above ? 'reached' : 'dropped to'} ${fmtPrice(a.price)}'),
          subtitle: Text('${a.firedAt == null ? '' : ago(a.firedAt!.toIso8601String())}${a.note.isEmpty ? '' : '  |  ${a.note}'}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: const Icon(Icons.replay), tooltip: 'Set again', onPressed: () { setState(() => alerts.remove(a)); addAlert(a.sym, a.price, a.note); }),
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { setState(() => alerts.remove(a)); saveAlerts(); }),
          ]),
        ),
    ]);
  }

  Widget signalsTab() {
    if (data == null) {
      return wrap([message(error ?? 'Loading signals...')]);
    }
    final all = (data!['signals'] as List? ?? []).cast<Map<String, dynamic>>();
    final list = all
        .where((s) => (filter == 'All' || s['side'] == filter) && (tfFilter == 'All' || s['tf'] == tfFilter))
        .toList();
    return wrap([
      Wrap(
        spacing: 8,
        children: [
          for (final f in ['All', 'BUY', 'SELL'])
            ChoiceChip(
              label: Text(f),
              selected: filter == f,
              onSelected: (_) => setState(() => filter = f),
            ),
        ],
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final f in ['All', '5m', '15m', '30m', '1h', '4h', '1d'])
            ChoiceChip(
              label: Text(f),
              selected: tfFilter == f,
              onSelected: (_) => setState(() => tfFilter = f),
            ),
        ],
      ),
      if (error != null) message(error!),
      if (list.isEmpty) message('No signals yet. The bot posts here when a setup appears.'),
      for (final s in list) signalCard(s),
    ]);
  }

  Widget signalCard(Map<String, dynamic> s) {
    final buy = s['side'] == 'BUY';
    final color = buy ? Colors.green : Colors.red;
    final agree = (s['agree'] as num?)?.toInt() ?? 1;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(buy ? Icons.arrow_upward : Icons.arrow_downward, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${s['side']} ${s['symbol']}',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600, color: color)),
                ),
                Text(agree > 1 ? '$agree agree' : '',
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 4),
            Text('${s['strategy']} (${s['tf']}) - ${s['style']}${s['grade'] == 'experimental' ? '  [experimental]' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            Text('Entry ${fmt(s['entry'])}   SL ${fmt(s['sl'])}   TP ${fmt(s['tp'])}'),
            const SizedBox(height: 4),
            Text('${s['why']}', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            Text(ago(s['time']), style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Future<String?> fetchPaperCsv() async {
    try {
      final url = feedUrl.replaceAll('feed.json', 'paper_log.csv');
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) {
        toast('Log not found yet (HTTP ${r.statusCode}). It appears after the updated bot has run once and closed a trade.');
        return null;
      }
      return utf8.decode(r.bodyBytes);
    } catch (e) {
      toast('Could not download the log: $e');
      return null;
    }
  }

  Future<void> downloadBotLog() async {
    final csv = await fetchPaperCsv();
    if (csv == null) return;
    await downloadCsv('paper_trading_log.csv', csv);
  }

  Future<void> shareLog() async {
    final csv = await fetchPaperCsv();
    if (csv == null) return;
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/paper_trading_log.csv');
      await f.writeAsString(csv);
      await Share.shareXFiles([XFile(f.path, mimeType: 'text/csv')], subject: 'Paper trading log');
    } catch (e) {
      toast('Could not share the file: $e');
    }
  }

  Future<void> copyLog() async {
    final csv = await fetchPaperCsv();
    if (csv == null) return;
    await Clipboard.setData(ClipboardData(text: csv));
    toast('Copied ${csv.trim().split('\n').length - 1} trades to the clipboard. Paste them into a chat or note.');
  }

  Widget exportCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Paper trading log', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('Every virtual trade as a CSV file: entry, stop, target, exit and reason, result in R, best and worst move after entry, plus ADX, RSI, news mood, 4h trend, hour and weekday at the time of the signal. Send it to tune the bot.', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            ElevatedButton.icon(onPressed: downloadBotLog, icon: const Icon(Icons.download), label: const Text('Download CSV')),
            OutlinedButton.icon(onPressed: shareLog, icon: const Icon(Icons.share), label: const Text('Share CSV')),
            OutlinedButton.icon(onPressed: copyLog, icon: const Icon(Icons.copy), label: const Text('Copy to clipboard')),
          ]),
          const SizedBox(height: 6),
          const Text('Also available in your GitHub repo at docs/paper_log.csv (open the file, then Download raw file).', style: TextStyle(fontSize: 11)),
        ]),
      ),
    );
  }

  Widget accountTab() {
    if (data == null) return wrap([message(error ?? 'Loading...')]);
    final p = (data!['paper'] as Map?)?.cast<String, dynamic>() ?? {};
    if (p.isEmpty) return wrap([message('Paper account starts after the first signal.'), exportCard()]);
    final eq = num0(p['equity']);
    final start = num0(p['start']);
    final pct = start > 0 ? (eq / start - 1) * 100 : 0;
    final strategies = (p['strategies'] as List? ?? []).cast<Map<String, dynamic>>();
    return wrap([
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Paper account (virtual money)'),
              Text('\$${eq.toStringAsFixed(0)}',
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
              Text('${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(1)}%   '
                  '${p['open']} open, ${p['closed']} closed'),
            ],
          ),
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Text('Results by strategy', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      if (strategies.isEmpty) message('No closed trades yet.'),
      for (final s in strategies)
        ListTile(
          dense: true,
          title: Text('${s['name']}'),
          subtitle: Text('${s['trades']} trades, ${s['win']}% wins'),
          trailing: Text('${num0(s['r']) >= 0 ? '+' : ''}${s['r']} R',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: num0(s['r']) >= 0 ? Colors.green : Colors.red)),
        ),
      exportCard(),
    ]);
  }

  Widget paperTab() {
    final open = trades.where((t) => t.isOpen).toList().reversed.toList();
    final closed = trades.where((t) => !t.isOpen).toList().reversed.toList();
    final st = PStats(trades);
    final eq = paperEquity;
    final pct = (eq / paperStart - 1) * 100;
    Color rc(double v) => v >= 0 ? Colors.green : Colors.red;
    String sgn(double v, [int d = 2]) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(d)}';
    Widget group(String title, Map<String, List<AppTrade>> g) {
      final keys = g.keys.toList()..sort((a, b) => g[b]!.length.compareTo(g[a]!.length));
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(4, 12, 4, 2), child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
        for (final k in keys.take(8))
          Builder(builder: (_) {
            final s = PStats(g[k]!);
            return ListTile(
              dense: true,
              title: Text(k),
              subtitle: Text('${s.n} trades, ${s.winPct.toStringAsFixed(0)}% wins, PF ${s.pf.toStringAsFixed(2)}'),
              trailing: Text('${sgn(s.sumR, 1)} R', style: TextStyle(fontWeight: FontWeight.w600, color: rc(s.sumR))),
            );
          }),
      ]);
    }
    Map<String, List<AppTrade>> by(String Function(AppTrade) f) {
      final m = <String, List<AppTrade>>{};
      for (final t in trades.where((t) => !t.isOpen)) {
        m.putIfAbsent(f(t), () => []).add(t);
      }
      return m;
    }
    return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(12), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Auto paper trading', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
              Switch(value: autoPaper, onChanged: setAutoPaper),
            ]),
            Text(autoPaper
                ? 'ON. When a candle closes on any chosen timeframe, the app checks the top $paperCoins coins and opens virtual trades from the signals that pass your filters. Keep the app open.'
                : 'OFF. Turn on to let the app open virtual trades on the top $paperCoins coins across the timeframes you choose, and track whether they hit target or stop.',
                style: const TextStyle(fontSize: 12)),
            if (paperStatus.isNotEmpty) Text(paperStatus, style: const TextStyle(fontSize: 11)),
            const SizedBox(height: 8),
            const Text('Coins (by 24h volume)', style: TextStyle(fontSize: 12)),
            Wrap(spacing: 8, children: [
              for (final n in [20, 50, 100])
                ChoiceChip(label: Text('Top $n'), selected: paperCoins == n, onSelected: (_) { setState(() => paperCoins = n); savePaper(); }),
            ]),
            const Text('Timeframes (5m scalping to 1d position)', style: TextStyle(fontSize: 12)),
            Wrap(spacing: 8, children: [
              for (final tf in mtfList)
                FilterChip(label: Text(tf), selected: paperTfs.contains(tf), onSelected: (v) {
                  setState(() { if (v) { paperTfs.add(tf); } else if (paperTfs.length > 1) { paperTfs.remove(tf); } });
                  savePaper();
                }),
            ]),
            const SizedBox(height: 8),
            const Text('Minimum signal strength', style: TextStyle(fontSize: 12)),
            Wrap(spacing: 8, children: [
              for (final o in const {'Any (0.2)': 0.2, 'Medium (0.35)': 0.35, 'Strong (0.5)': 0.5}.entries)
                ChoiceChip(label: Text(o.key), selected: paperMinScore == o.value, onSelected: (_) { setState(() => paperMinScore = o.value); savePaper(); }),
            ]),
            const Text('Minimum ADX (trend strength). The Lab found no edge below 20', style: TextStyle(fontSize: 12)),
            Wrap(spacing: 8, children: [
              for (final o in const {'Off': 0, '20': 20, '25': 25, '30': 30}.entries)
                ChoiceChip(label: Text(o.key), selected: paperMinAdx == o.value, onSelected: (_) { setState(() => paperMinAdx = o.value); savePaper(); }),
            ]),
            const Text('Quality filter (higher timeframes, Bitcoin trend, volume, closed-candle check)', style: TextStyle(fontSize: 12)),
            Wrap(spacing: 8, children: [
              for (final o in const {'Off': 0, '3 of 5': 3, '4 of 5': 4}.entries)
                ChoiceChip(label: Text(o.key), selected: paperMinQ == o.value, onSelected: (_) { setState(() => paperMinQ = o.value); savePaper(); }),
            ]),
            if (paperRejected > 0) Text('Filtered out $paperRejected weak setups this session.', style: const TextStyle(fontSize: 11)),
            const Text('Max open trades', style: TextStyle(fontSize: 12)),
            Wrap(spacing: 8, children: [
              for (final n in [20, 50, 100])
                ChoiceChip(label: Text('$n'), selected: paperMaxOpen == n, onSelected: (_) { setState(() => paperMaxOpen = n); savePaper(); }),
            ]),
            const SizedBox(height: 6),
            const Text('Stop and target come from the same trade plan shown in Markets. Trades also need at least 1.2 reward to risk, one open trade per coin and timeframe, and none open during a high-impact news window. Same-candle stop and target counts as a loss, and 0.05R is charged for fees.', style: TextStyle(fontSize: 11)),
          ]),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('In-app paper account (virtual money)'),
            Text('\$${eq.toStringAsFixed(0)}', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
            Text('${sgn(pct, 1)}%   ${open.length} open, ${st.n} closed'),
            if (st.n > 0) ...[
              const SizedBox(height: 6),
              Text('Accuracy: ${st.winPct.toStringAsFixed(0)}% win rate (${st.wins} of ${st.n})'),
              Text('Average ${sgn(st.avgR)}R per trade, profit factor ${st.pf.toStringAsFixed(2)}, total ${sgn(st.sumR, 1)}R'),
              Text('Hit target ${st.tp}, hit stop ${st.sl}, timed out ${st.timeouts}', style: const TextStyle(fontSize: 12)),
            ],
          ]),
        ),
      ),
      if (st.n > 0)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('What the results say', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              for (final line in paperInsights()) Padding(padding: const EdgeInsets.only(top: 3), child: Text('• $line', style: const TextStyle(fontSize: 12))),
            ]),
          ),
        ),
      if (open.isNotEmpty) ...[
        const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 2), child: Text('Open trades', style: TextStyle(fontWeight: FontWeight.w600))),
        for (final t in open)
          ListTile(
            dense: true,
            title: Text('${t.coin} ${t.side == 1 ? 'BUY' : 'SELL'} (${t.tf})', style: TextStyle(fontWeight: FontWeight.w600, color: t.side == 1 ? Colors.green : Colors.red)),
            subtitle: Text('Entry ${fmtPrice(t.entry)}  SL ${fmtPrice(t.sl)}  TP ${fmtPrice(t.tp)}\n${t.verdict}, ${ago(t.opened.toIso8601String())}, best ${t.mfe.toStringAsFixed(1)}R / worst ${t.mae.toStringAsFixed(1)}R'),
            isThreeLine: true,
          ),
      ],
      if (st.n > 0) ...[
        group('By timeframe', by((t) => t.tf)),
        group('By trading style', by((t) => styleOf(t.tf))),
        group('By direction', by((t) => t.side == 1 ? 'BUY' : 'SELL')),
        group('By signal strength', by((t) => t.score.abs() >= .5 ? 'Strong (0.5+)' : t.score.abs() >= .35 ? 'Medium (0.35-0.5)' : 'Weak (0.2-0.35)')),
        group('By quality score', by((t) => t.quality == 0 ? 'Unfiltered' : 'Quality ${t.quality} of 5')),
        group('By coin', by((t) => t.coin)),
      ],
      if (closed.isNotEmpty) ...[
        const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 2), child: Text('Recent closed trades', style: TextStyle(fontWeight: FontWeight.w600))),
        for (final t in closed.take(25))
          ListTile(
            dense: true,
            title: Text('${t.coin} ${t.side == 1 ? 'BUY' : 'SELL'} (${t.tf})  ${t.reason}${t.ambiguous ? ' *' : ''}'),
            subtitle: Text('${ago(t.closed?.toIso8601String())}, ${t.verdict}'),
            trailing: Text('${sgn(t.r)} R', style: TextStyle(fontWeight: FontWeight.w600, color: rc(t.r))),
          ),
        const Text('* stop and target were both touched in the same candle, counted as a stop.', style: TextStyle(fontSize: 11)),
      ],
      if (trades.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No trades yet. Turn on Auto paper trading, or open a coin in Markets and tap Paper trade.', textAlign: TextAlign.center)),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Download logs to tune the bot', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('In-app log: every trade with entry, stop, target, exit and reason, result in R, best and worst move after entry, verdict, score, indicator counts, ADX, ATR %, news mood, hour and weekday. The bot log uses the same column names, so you can compare them.', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              ElevatedButton.icon(onPressed: downloadAppLog, icon: const Icon(Icons.download), label: const Text('Download app log')),
              OutlinedButton.icon(onPressed: shareAppLog, icon: const Icon(Icons.share), label: const Text('Share app log')),
              OutlinedButton.icon(onPressed: copyAppLog, icon: const Icon(Icons.copy), label: const Text('Copy')),
              OutlinedButton.icon(onPressed: downloadBotLog, icon: const Icon(Icons.download), label: const Text('Download bot log')),
              OutlinedButton.icon(onPressed: shareLog, icon: const Icon(Icons.smart_toy), label: const Text('Share bot log')),
              OutlinedButton.icon(onPressed: downloadAllLogs, icon: const Icon(Icons.download_for_offline), label: const Text('Download all logs')),
              OutlinedButton.icon(onPressed: shareBothLogs, icon: const Icon(Icons.share), label: const Text('Share all logs')),
            ]),
            const SizedBox(height: 6),
            Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: trades.isEmpty ? null : resetPaper, icon: const Icon(Icons.delete_outline), label: const Text('Reset in-app paper account'))),
          ]),
        ),
      ),
      const Padding(padding: EdgeInsets.only(top: 8), child: Text('Trades are opened and checked only while the app is running. When you reopen it, the app replays candles since entry, so stops and targets that were hit meanwhile are still recorded. Virtual money, not financial advice.', style: TextStyle(fontSize: 11))),
    ]);
  }

  Widget labTab() {
    const styles = ['All', 'Scalping', 'Intraday', 'Swing', 'Position'];
    const cats = ['All', 'Overall verdict', 'Trend', 'Momentum / oscillators', 'Volume', 'Breakout / volatility', 'Support / resistance', 'Candle patterns'];
    const minN = 30;
    // rows for the chosen style
    final entries = <MapEntry<String, List<double>>>[];
    labAgg.forEach((k, a) {
      final i = k.lastIndexOf('|');
      if (k.substring(i + 1) != labStyle) return;
      final name = k.substring(0, i);
      if (labCat != 'All' && categoryOf(name) != labCat) return;
      entries.add(MapEntry(name, a));
    });
    double? raceWin(List<double> a) => a[2] + a[3] > 0 ? a[2] / (a[2] + a[3]) : null;
    double score(MapEntry<String, List<double>> e) => e.value[0] < minN ? -9 : (raceWin(e.value) ?? .5);
    entries.sort((a, b) => score(b).compareTo(score(a)));
    // category summary (all indicators in a category pooled)
    final catSum = <String, List<double>>{};
    labAgg.forEach((k, a) {
      final i = k.lastIndexOf('|');
      if (k.substring(i + 1) != labStyle) return;
      final c = categoryOf(k.substring(0, i));
      final t = catSum.putIfAbsent(c, () => [0, 0, 0, 0, 0]);
      for (var x = 0; x < 5; x++) {
        t[x] += a[x];
      }
    });
    // style summary of the overall verdict
    final styleSum = <String, List<double>?>{for (final st in styles.skip(1)) st: labAgg['OVERALL verdict|$st']};
    Color wc(double? w, double n) => n < minN || w == null ? Colors.grey : w >= .55 ? Colors.green : w <= .45 ? Colors.red : Colors.orange;
    String pct(double? w) => w == null ? '-' : '${(w * 100).toStringAsFixed(0)}%';
    return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(12), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Signal Lab', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
              Switch(value: labOn, onChanged: setLabOn),
            ]),
            const Text('Records what every indicator said on the top coins at each candle close (15m, 1h, 4h, 1d), then checks what price did over the next 6 candles. Race test: did price move 1.5 ATR your way before 1.5 ATR against you. About 50% is a coin flip, so only results well away from 50% with 30+ signals mean anything.', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            const Text('Coins to follow', style: TextStyle(fontSize: 12)),
            Wrap(spacing: 8, children: [
              for (final n in [10, 20, 40])
                ChoiceChip(label: Text('Top $n'), selected: labCoins == n, onSelected: (_) { setState(() => labCoins = n); saveLab(); }),
              FilterChip(label: const Text('Add 5m scalping'), selected: lab5m, onSelected: (v) { setState(() => lab5m = v); saveLab(); }),
            ]),
            if (labStatus.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(labStatus, style: const TextStyle(fontSize: 11))),
            if (labBusy) const Padding(padding: EdgeInsets.only(top: 6), child: LinearProgressIndicator()),
          ]),
        ),
      ),
      if (labAgg.isEmpty)
        const Padding(padding: EdgeInsets.all(24), child: Text('No scored signals yet. Turn the Lab on and keep the app open. The first results arrive about 90 minutes later (6 candles on 15m), 6 hours for 1h, a day for 4h and 6 days for 1d. Everything is saved on the phone between sessions.', textAlign: TextAlign.center))
      else ...[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Trading styles: overall verdict accuracy', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              for (final e in styleSum.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: e.value == null
                      ? Text('${e.key}: collecting', style: const TextStyle(fontSize: 12))
                      : Text('${e.key}: ${e.value![0].toInt()} signals, race win ${pct(raceWin(e.value!))}, direction right ${(100 * e.value![1] / e.value![0]).toStringAsFixed(0)}%, avg ${(e.value![4] / e.value![0]).toStringAsFixed(2)} ATR',
                          style: TextStyle(fontSize: 12, color: wc(raceWin(e.value!), e.value![0]))),
                ),
              const SizedBox(height: 4),
              const Text('Scalping = 15m (and 5m if added), Intraday = 1h, Swing = 4h, Position = 1d.', style: TextStyle(fontSize: 11)),
            ]),
          ),
        ),
        Wrap(spacing: 8, children: [for (final x in styles) ChoiceChip(label: Text(x), selected: labStyle == x, onSelected: (_) => setState(() => labStyle = x))]),
        if (catSum.isNotEmpty) ...[
          const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 2), child: Text('Indicator families (pooled)', style: TextStyle(fontWeight: FontWeight.w600))),
          for (final e in (catSum.entries.toList()..sort((a, b) => (raceWin(b.value) ?? 0).compareTo(raceWin(a.value) ?? 0))))
            ListTile(
              dense: true,
              title: Text(e.key),
              subtitle: Text('${e.value[0].toInt()} signals, direction right ${(100 * e.value[1] / e.value[0]).toStringAsFixed(0)}%'),
              trailing: Text('race ${pct(raceWin(e.value))}', style: TextStyle(fontWeight: FontWeight.w600, color: wc(raceWin(e.value), e.value[0]))),
            ),
        ],
        const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 2), child: Text('Every indicator, best first', style: TextStyle(fontWeight: FontWeight.w600))),
        Wrap(spacing: 6, children: [for (final x in cats) ChoiceChip(label: Text(x, style: const TextStyle(fontSize: 11)), selected: labCat == x, onSelected: (_) => setState(() => labCat = x))]),
        if (entries.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No data for this style yet.')),
        for (final e in entries.take(80))
          ListTile(
            dense: true,
            title: Text(e.key),
            subtitle: Text('${e.value[0].toInt()} signals${e.value[0] < minN ? ' (need $minN+)' : ''}, direction right ${(100 * e.value[1] / e.value[0]).toStringAsFixed(0)}%, avg ${(e.value[4] / e.value[0]).toStringAsFixed(2)} ATR'),
            trailing: Text('race ${pct(raceWin(e.value))}', style: TextStyle(fontWeight: FontWeight.w600, color: wc(raceWin(e.value), e.value[0]))),
          ),
      ],
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Download Lab data', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Accuracy table: one row per indicator and style. Snapshots: the raw vote of every indicator at each signal with what happened next (last 1,500). Send these to tune the bot.', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              ElevatedButton.icon(onPressed: shareLabAcc, icon: const Icon(Icons.download), label: const Text('Accuracy table')),
              OutlinedButton.icon(onPressed: shareLabRows, icon: const Icon(Icons.table_chart), label: const Text('Raw snapshots')),
              OutlinedButton.icon(onPressed: downloadAllLogs, icon: const Icon(Icons.download_for_offline), label: const Text('Download all logs')),
              OutlinedButton.icon(onPressed: shareBothLogs, icon: const Icon(Icons.share), label: const Text('Share all logs')),
            ]),
            Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: resetLab, icon: const Icon(Icons.delete_outline), label: const Text('Reset Lab'))),
          ]),
        ),
      ),
      const Padding(padding: EdgeInsets.only(top: 8), child: Text('Collecting only happens while the app is open. Past results never guarantee future ones, and an indicator can look good over a short window by luck. Trust it only with hundreds of signals.', style: TextStyle(fontSize: 11))),
    ]);
  }

  Widget reportTab() {
    if (data == null) return wrap([message(error ?? 'Loading...')]);
    final text = '${data!['report'] ?? ''}';
    return wrap([
      if (text.isEmpty)
        message('The daily report appears here after 06:00 UTC.')
      else
        SelectableText(text, style: const TextStyle(height: 1.5)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 9,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Signal Bot'),
          actions: [
            if (loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              IconButton(icon: const Icon(Icons.refresh), onPressed: load),
          ],
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(text: 'Markets'),
            Tab(text: 'Scanner'),
            Tab(text: 'Signals'),
            Tab(text: 'News'),
            Tab(text: 'Alerts'),
            Tab(text: 'Account'),
            Tab(text: 'Paper'),
            Tab(text: 'Lab'),
            Tab(text: 'Report'),
          ]),
        ),
        body: Column(
          children: [
            if (data != null && '${data!['updated']}'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Updated ${ago(data!['updated'])}', style: const TextStyle(fontSize: 12)),
              ),
            Expanded(
              child: TabBarView(children: [marketTab(), scannerTab(), signalsTab(), newsTab(), alertsTab(), accountTab(), paperTab(), labTab(), reportTab()]),
            ),
            const Padding(
              padding: EdgeInsets.all(6),
              child: Text('Analysis only, not financial advice.', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }
}


class Candle {
  final DateTime time;
  final double open, high, low, close, volume;
  Candle(this.time, this.open, this.high, this.low, this.close, [this.volume = 0]);
}

class CandlePainter extends CustomPainter {
  final List<Candle> candles;
  final bool dark;
  final List<double> sup, res;
  CandlePainter(this.candles, this.dark, [this.sup = const [], this.res = const []]);
  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.width <= 0 || size.height <= 0) return;
    final minV = candles.map((c)=>c.low).reduce(math.min);
    final maxV = candles.map((c)=>c.high).reduce(math.max);
    final range = (maxV-minV).abs() < 1e-9 ? 1.0 : maxV-minV;
    final pad = 12.0;
    double y(double v) => size.height-pad-(v-minV)/range*(size.height-pad*2);
    final grid = Paint()..color = (dark ? Colors.white : Colors.black).withOpacity(.12)..strokeWidth=1;
    for (int i=0;i<5;i++) { final yy=pad+(size.height-pad*2)*i/4; canvas.drawLine(Offset(0,yy),Offset(size.width,yy),grid); }
    final step = size.width/candles.length;
    final bodyW = math.max(2.0, step*.62);
    for (int i=0;i<candles.length;i++) {
      final c=candles[i]; final x=step*(i+.5); final color=c.close>=c.open?Colors.green:Colors.red;
      final wick=Paint()..color=color..strokeWidth=1.2;
      canvas.drawLine(Offset(x,y(c.high)),Offset(x,y(c.low)),wick);
      final top=math.min(y(c.open),y(c.close)); final bottom=math.max(y(c.open),y(c.close));
      final rect=Rect.fromLTRB(x-bodyW/2,top,x+bodyW/2,math.max(top+1,bottom));
      canvas.drawRect(rect,Paint()..color=color);
    }
    final tp=TextPainter(textDirection: TextDirection.ltr);
    void level(double v, Color col) {
      if (v < minV || v > maxV) return;
      final yy = y(v);
      final p = Paint()..color = col.withOpacity(.75)..strokeWidth = 1;
      for (double x = 0; x < size.width; x += 10) { canvas.drawLine(Offset(x, yy), Offset(math.min(x + 5, size.width), yy), p); }
      tp.text = TextSpan(text: fmtPrice(v), style: TextStyle(fontSize: 10, color: col));
      tp.layout();
      tp.paint(canvas, Offset(size.width - tp.width - 2, yy - 12));
    }
    for (final v in sup) { level(v, Colors.green); }
    for (final v in res) { level(v, Colors.red); }
    tp.text=TextSpan(text:fmtPrice(maxV),style:TextStyle(fontSize:10,color:dark?Colors.white70:Colors.black54)); tp.layout(); tp.paint(canvas,Offset(2,0));
    tp.text=TextSpan(text:fmtPrice(minV),style:TextStyle(fontSize:10,color:dark?Colors.white70:Colors.black54)); tp.layout(); tp.paint(canvas,Offset(2,size.height-14));
  }
  @override
  bool shouldRepaint(covariant CandlePainter oldDelegate) => true;
}

extension TakeLastList<E> on List<E> {
  List<E> takeLast(int count) => skip(math.max(0, length-count)).toList();
}
