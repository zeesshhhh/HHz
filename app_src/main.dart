import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, ZLibCodec;
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

// Indicators whose 'race' accuracy in the Lab (1,190 signal sets, Oct 30-31) was below 50%. They stay on screen and keep being
// scored by the Lab, but are shown as "info only" and no longer vote in the verdict. Re-check after more Lab data.
const droppedIndicators = <String>{
  'EMA 20', 'EMA 30', 'EMA 50', 'EMA 100', 'EMA 200', 'SMA 20', 'SMA 30', 'SMA 50', 'SMA 200', 'VWAP (50)', 'VWMA (20)',
  'Supertrend (10,3)', 'Ichimoku', 'Chandelier Exit (22,3)', 'Vortex (14)', 'Aroon (25)', 'ADX (14)', 'TRIX (15)', 'ROC (12)',
  'Awesome Oscillator', 'Squeeze Momentum', 'OBV vs EMA21', 'Chaikin Money Flow (20)', 'Candle pattern',
};
bool isInfoOnly(Reading r) => r.mr || droppedIndicators.contains(r.name);

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
  // ---- candidate indicators: scored by the Lab but "info only" until the Lab shows a real edge (55%+ over 300+ results)
  if (n >= 30) {
    final r2 = rsiSeries(c, 2).last;
    osc.add(Reading('RSI (2)', f1(r2), r2 < 10 ? 1 : r2 > 90 ? -1 : 0, true));
    final m20 = smaLast(c, 20);
    var sq = 0.0;
    for (var i = n - 20; i < n; i++) {
      sq += (c[i] - m20) * (c[i] - m20);
    }
    final sd = math.sqrt(sq / 20);
    if (sd > 0) {
      final zz = (last - m20) / sd;
      osc.add(Reading('Z-score (20)', f1(zz), zz < -2 ? 1 : zz > 2 ? -1 : 0, true));
    }
    final e20 = emaSeries(c, 20);
    final slope = (e20.last - e20[n - 4]) / (atr > 0 ? atr : 1);
    osc.add(Reading('EMA20 slope (3 bars)', f1(slope), slope > 0.3 ? 1 : slope < -0.3 ? -1 : 0, true));
    if (hasVol) {
      var av = 0.0;
      for (var i = n - 21; i < n - 1; i++) {
        av += v[i];
      }
      av /= 20;
      final rv = av > 0 ? v[n - 1] / av : 0.0;
      final up = c[n - 1] > cs.last.open;
      osc.add(Reading('Volume surge candle', '${f1(rv)}x', rv >= 1.8 ? (up ? 1 : -1) : 0, true));
    }
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
    if (isInfoOnly(r)) continue;
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
    if (isInfoOnly(r)) continue;
    final w = edgeWeight[r.name] ?? 1.0;
    wsum += w;
    ssum += w * r.sig;
  }
  final score = wsum == 0 ? 0.0 : ssum / wsum;
  return Analysis(ma, osc, info, b, s, z, last, atr, adxV, score, sups.take(3).toList(), ress.take(3).toList());
}

/// Up to 500 candles that end before [before] (Binance coins only), for scrolling the chart into the past.
Future<List<Candle>> fetchOlderCandles(String sym, String tf, DateTime before) async {
  if (yahooPairs.containsKey(sym)) return <Candle>[];
  final pair = futSymbols[sym] ?? '${sym}USDT';
  final q = {'symbol': pair, 'interval': tf, 'limit': '500', 'endTime': '${before.millisecondsSinceEpoch - 1}'};
  var r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/klines', q)).timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) {
    r = await http.get(Uri.https('api.binance.com', '/api/v3/klines', q)).timeout(const Duration(seconds: 15));
  }
  if (r.statusCode != 200) throw 'Older candles unavailable (HTTP ${r.statusCode}).';
  return (jsonDecode(r.body) as List)
      .map((x) => Candle(DateTime.fromMillisecondsSinceEpoch((x[0] as num).toInt()), double.parse('${x[1]}'),
          double.parse('${x[2]}'), double.parse('${x[3]}'), double.parse('${x[4]}'), double.parse('${x[5]}')))
      .where((c) => c.time.isBefore(before))
      .toList();
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

/// Coins a headline can be traded on (curated names, so 'near', 'link' or 'trump' in normal English do not trigger trades).
const newsCoinKeys = {
  'BTC': ['bitcoin', ' btc'], 'ETH': ['ethereum', ' eth '], 'SOL': ['solana'], 'BNB': [' bnb', 'binance coin'], 'XRP': [' xrp', 'ripple'],
  'DOGE': ['dogecoin', ' doge'], 'ADA': ['cardano'], 'AVAX': ['avalanche'], 'LINK': ['chainlink'], 'DOT': ['polkadot'], 'LTC': ['litecoin'],
  'TRX': [' tron '], 'TON': ['toncoin'], 'SUI': [' sui '], 'SHIB': ['shiba inu'], 'UNI': ['uniswap'], 'AAVE': [' aave'], 'ARB': ['arbitrum'],
  'OP': ['optimism'], 'APT': ['aptos'], 'HYPE': ['hyperliquid'], 'ENA': ['ethena'], 'WLD': ['worldcoin'], 'BCH': ['bitcoin cash'],
  'PEPE': [' pepe'], 'XLM': ['stellar'], 'HBAR': ['hedera'], 'NEAR': ['near protocol'], 'ATOM': ['cosmos'], 'FIL': ['filecoin'],
};
const newsStopAtr = 1.5;   // news trades: stop 1.5 ATR(14) of the trade's timeframe, target = your reward:risk setting

double atrWilder(List<Candle> cs, [int n = 14]) {
  if (cs.length <= n) return double.nan;
  double? a;
  for (var i = 1; i < cs.length; i++) {
    final c = cs[i], pc = cs[i - 1].close;
    final tr = math.max(c.high - c.low, math.max((c.high - pc).abs(), (c.low - pc).abs()));
    a = a == null ? tr : (a * (n - 1) + tr) / n;
  }
  return a ?? double.nan;
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});
int crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Minimal ZIP writer (deflate from dart:io), so all logs can be saved as one file without an extra package.
Uint8List zipFiles(Map<String, String> files) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  final now = DateTime.now();
  final dosTime = (now.hour << 11) | (now.minute << 5) | (now.second ~/ 2);
  final dosDate = ((now.year - 1980) << 9) | (now.month << 5) | now.day;
  var count = 0;
  void u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  for (final e in files.entries) {
    final name = utf8.encode(e.key);
    final raw = utf8.encode(e.value);
    final comp = ZLibCodec(raw: true, level: 6).encode(raw);
    final crc = crc32(raw);
    final offset = out.length;
    u32(out, 0x04034b50); u16(out, 20); u16(out, 0x0800); u16(out, 8); u16(out, dosTime); u16(out, dosDate);
    u32(out, crc); u32(out, comp.length); u32(out, raw.length); u16(out, name.length); u16(out, 0);
    out.add(name); out.add(comp);
    u32(central, 0x02014b50); u16(central, 20); u16(central, 20); u16(central, 0x0800); u16(central, 8); u16(central, dosTime); u16(central, dosDate);
    u32(central, crc); u32(central, comp.length); u32(central, raw.length); u16(central, name.length); u16(central, 0); u16(central, 0);
    u16(central, 0); u16(central, 0); u32(central, 0); u32(central, offset);
    central.add(name);
    count++;
  }
  final cdOffset = out.length, cd = central.takeBytes();
  out.add(cd);
  u32(out, 0x06054b50); u16(out, 0); u16(out, 0); u16(out, count); u16(out, count); u32(out, cd.length); u32(out, cdOffset); u16(out, 0);
  return out.takeBytes();
}

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

/// Words after "after", "despite" or "following" describe the background, not the news itself
/// ("withdrawals resume after $49M hack" is not bearish), so only the part before them is scored.
String newsHead(String t) {
  var x = ' ${t.toLowerCase()} ';
  for (final w in const [' after ', ' despite ', ' following ']) {
    final i = x.indexOf(w);
    if (i > 0) x = '${x.substring(0, i)} ';
  }
  return x;
}

int scoreTitle(String t) {
  final x = newsHead(t);
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

/// Target distance as a multiple of the stop distance (1.0 = 1:1). Set in the Paper settings; applies to new trades.
double planRR = 1.0;   // reward to risk; chips 1:1 / 1:1.5 / 1:2 or a custom value (0.5 to 10)
String fmtRR(double r) { final s = r.toStringAsFixed(2); return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), ''); }

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
  var tp = a.last + side * risk * planRR;           // reward to risk, 1:1 by default
  final tgt = side == 1 ? (a.res.isEmpty ? double.nan : a.res.first) : (a.sup.isEmpty ? double.nan : a.sup.first);
  if (!tgt.isNaN) {
    final dist = (tgt - a.last).abs();
    if (dist >= 0.8 * risk * planRR && dist < risk * planRR) tp = tgt;   // a nearby level just before the target
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

/// Keeps the app process alive (Android foreground service) while auto paper trading is on, so it keeps scanning when the app
/// is minimized or the screen is off. Swiping the app away from recent apps still stops it.
Future<void> setBackgroundService(bool on) async {
  try {
    final android = notifier.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    if (on) {
      await android.startForegroundService(
        7001, 'Signal Bot is running', 'Auto paper trading is active. Tap to open.',
        notificationDetails: const AndroidNotificationDetails('bg_service', 'Background running',
            channelDescription: 'Keeps auto paper trading running when the app is minimized',
            importance: Importance.low, priority: Priority.low, ongoing: true, playSound: false, enableVibration: false),
        foregroundServiceTypes: {AndroidServiceForegroundType.foregroundServiceTypeDataSync},
      );
    } else {
      await android.stopForegroundService();
    }
  } catch (_) {}
}

Future<void> notifyPaper(int id, String title, String body) async {
  try {
    const details = NotificationDetails(
      android: AndroidNotificationDetails('paper_trades', 'Paper trades',
          channelDescription: 'Tells you when a paper trade opens or closes', importance: Importance.max, priority: Priority.high, playSound: true, enableVibration: true),
    );
    await notifier.show(100000 + id, title, body, details);
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

// ---------- live market quotes, market regime and the signal gate ----------
/// Best bid/ask snapshot for one coin. A BUY is closed at the bid and a SELL at the ask, so unrealized P&L uses the executable side.
class LiveQuote {
  final double bid, ask, last;
  final DateTime at;
  final String source;
  LiveQuote(this.bid, this.ask, this.last, this.at, this.source);
  double exitPrice(int side) => side == 1 ? bid : ask;
  int get ageSec => DateTime.now().difference(at).inSeconds;
  String get status => ageSec <= 12 ? 'LIVE' : ageSec <= 60 ? 'STALE' : 'OFFLINE';
}

/// Binance best bid/ask for every symbol in one request (futures, or spot as the fallback). symbol -> [bid, ask]
Future<Map<String, List<double>>> fetchBookTickers({bool spot = false}) async {
  final out = <String, List<double>>{};
  try {
    final uri = spot ? Uri.https('api.binance.com', '/api/v3/ticker/bookTicker') : Uri.https('fapi.binance.com', '/fapi/v1/ticker/bookTicker');
    final r = await http.get(uri).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return out;
    for (final e in jsonDecode(r.body) as List) {
      final b = double.tryParse('${e['bidPrice']}'), a = double.tryParse('${e['askPrice']}');
      if (b != null && a != null && b > 0 && a > 0) out['${e['symbol']}'] = [b, a];
    }
  } catch (_) {}
  return out;
}

String exchangeLabel(String coin) => yahooPairs.containsKey(coin) ? 'Yahoo Finance' : (futSymbols.containsKey(coin) ? 'Binance Futures' : 'Binance Spot');

String sinceText(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '${d.inSeconds}s';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inHours < 48) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inDays}d ${d.inHours % 24}h';
}

/// Unrealized result of an open trade at the executable exit price, with the same fee model as settled trades.
class LivePnl {
  final double px, r, usd, pct, tpProgress, slDistPct, slDistR;
  LivePnl(this.px, this.r, this.usd, this.pct, this.tpProgress, this.slDistPct, this.slDistR);
}

LivePnl? livePnl(AppTrade t, LiveQuote? q) {
  if (q == null || t.riskPx <= 0 || t.entry <= 0) return null;
  final px = q.exitPrice(t.side);
  final r = (px - t.entry) * t.side / t.riskPx - paperCostR;
  final tpDist = (t.tp - t.entry).abs();
  return LivePnl(px, r, r * t.riskCash, (px - t.entry) * t.side / t.entry * 100,
      tpDist == 0 ? 0 : (px - t.entry) * t.side / tpDist * 100,
      px == 0 ? 0 : (px - t.sl) * t.side / px * 100, (px - t.sl) * t.side / t.riskPx);
}

class GateReject {
  final DateTime at;
  final String coin, tf, reason;
  final int side;
  GateReject(this.at, this.coin, this.tf, this.side, this.reason);
}

class Regime {
  final String label, note;
  final bool tradable;       // for the direction that was asked about
  const Regime(this.label, this.tradable, this.note);
}

double medianOf(List<double> v) {
  if (v.isEmpty) return double.nan;
  final s = [...v]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

/// Market regime from ADX (trend strength), ATR versus its own 100-candle median (volatility) and EMA20/EMA50 position.
/// These thresholds are sensible defaults, not values validated by a backtest.
Regime detectRegime({required int side, required double adx, required double atrRatio, required double emaFast,
    required double emaSlow, required double last, required double rsi}) {
  if (!atrRatio.isNaN) {
    if (atrRatio >= 2.0) return Regime('High volatility', false, 'ATR is ${atrRatio.toStringAsFixed(1)}x its normal level, stops get hit by noise');
    if (atrRatio <= 0.5) return Regime('Low volatility', false, 'ATR is only ${atrRatio.toStringAsFixed(1)}x its normal level, moves are too small to beat costs');
  }
  final up = emaFast > emaSlow, down = emaFast < emaSlow;
  final trending = !adx.isNaN && adx >= 25;
  if (trending && up && last > emaFast) return Regime('Strong uptrend', side == 1, 'a SELL goes against a strong uptrend');
  if (trending && down && last < emaFast) return Regime('Strong downtrend', side == -1, 'a BUY goes against a strong downtrend');
  if (up && last < emaFast && !rsi.isNaN && rsi < 45) return Regime('Possible reversal down', side == -1, 'the trend is turning down, a BUY is premature');
  if (down && last > emaFast && !rsi.isNaN && rsi > 55) return Regime('Possible reversal up', side == 1, 'the trend is turning up, a SELL is premature');
  if (!adx.isNaN && adx < 20) return const Regime('Sideways / ranging', true, '');
  return const Regime('Mixed trend', true, '');
}

// Signal gate limits, separate for BUY (1) and SELL (-1). Defaults are equal because the data so far is too small to justify
// different values: tune them from your own CSV results.
const gateExtMax = {1: 1.2, -1: 1.2};            // max ATR distance from EMA20 in the trade direction (anti-chasing)
const gateRsiLimit = {1: 70.0, -1: 30.0};        // BUY blocked above, SELL blocked below
const gateMinScoreAdd = {1: 0.0, -1: 0.0};       // extra score required on top of the minimum signal strength
const gateSrMinAtr = 0.5;                        // opposing support/resistance must be at least this many ATR away
const gateLateMoveAtr = 3.0;                     // max move in the trade direction over the last 5 candles
const gateCandleBodyAtr = 0.7;                   // reject if the last closed candle is a strong move against the signal
// EXPERIMENT (Nov 1 Lab): trend SELLs were opened while price was already oversold (97 of 105 had a stretch indicator at oversold)
// and won 18%. Veto a trend trade when at least this many of the stretch indicators say price is already stretched AGAINST the
// direction (oversold for a SELL, overbought for a BUY). 0 = off. BUY is off because the same test blocked mostly winning BUYs.
// One 40 minute window in a rising market: re-test on a falling day before trusting it.
const gateStretchVeto = {1: 0, -1: 2};
const stretchInds = ['RSI (14)', 'Z-score (20)', 'Bollinger %B (20,2)', 'CCI (20)', 'MFI (14)', 'RSI (2)'];

/// Mean-reversion BUY setup (experimental, tracked as its own strategy "App MR"). The Lab's best indicators (Z-score, RSI(2), CCI,
/// Bollinger %B, MFI, Stochastic RSI, Williams %R) all measure "how stretched is price", so they are treated as one idea:
/// the Z-score must fire and at least one more must agree. Lab data (Nov 1): after such BUY signals price rose 64% of the time,
/// average +0.43 ATR (n=42, both halves positive). SELL signals went the wrong way (price rose +0.6 ATR on average), so SELL is off.
const mrAllowSell = false;

class MrSignal {
  final int side;
  final String inds;   // '|' separated names of the stretch indicators that agreed
  const MrSignal(this.side, this.inds);
}

int sigOf(Analysis a, String name) {
  for (final r in [...a.ma, ...a.osc]) {
    if (r.name == name) return r.sig;
  }
  return 0;
}

MrSignal? mrSignal(Analysis ac) {
  if (ac.atr <= 0 || ac.last <= 0) return null;
  final z = sigOf(ac, 'Z-score (20)');
  if (z == 0 || (z == -1 && !mrAllowSell)) return null;
  final names = <String>['Z-score (20)'];
  for (final n in const ['RSI (2)', 'RSI (14)', 'CCI (20)', 'Bollinger %B (20,2)', 'MFI (14)', 'Stochastic RSI', 'Williams %R (14)']) {
    if (sigOf(ac, n) == z) names.add(n);
  }
  if (names.length < 2) return null;
  return MrSignal(z, names.join('|'));
}

class AppTrade {
  final int id, side, buys, sells, neutrals, mood;
  final String coin, tf, source, verdict;
  final String regime, inds;   // market regime at entry and the indicators that agreed ('|' separated)
  final double entry, sl, tp, score, riskCash;
  String path;                 // unrealized R every ~5 minutes while the trade is open (';' separated), for testing exits later
  DateTime? pathAt;
  final double amount;         // position size in USD chosen for this trade (0 = older trade, sized by the 1% risk rule)
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
      this.rvol, this.ext, this.quality = 0, this.htfAgree = 0, this.btc = 0, this.regime = '', this.inds = '', this.amount = 0, this.path = ''});

  bool get isOpen => status == 'open';
  double get riskPx => (entry - sl).abs();
  double get plannedRR => riskPx > 0 ? (tp - entry).abs() / riskPx : 0.0;
  /// Position size in USD: the amount typed in Settings, or the size implied by the 1% risk rule.
  double get notional => amount > 0 ? amount : (riskPx > 0 ? riskCash * entry / riskPx : 0.0);
  double get pnl => r * riskCash;
  double get plannedRr => riskPx == 0 ? 0 : (tp - entry).abs() / riskPx;

  Map<String, dynamic> toJson() => {
        'id': id, 'coin': coin, 'tf': tf, 'source': source, 'verdict': verdict, 'side': side, 'buys': buys,
        'sells': sells, 'neutrals': neutrals, 'mood': mood, 'entry': entry, 'sl': sl, 'tp': tp, 'score': score,
        'risk': riskCash, 'adx': cleanNum(adx), 'atrPct': cleanNum(atrPct), 'opened': opened.toIso8601String(),
        'status': status, 'reason': reason, 'mfe': mfe, 'mae': mae, 'exit': exitPx, 'r': r, 'amb': ambiguous,
        'closed': closed?.toIso8601String(),
        'rvol': cleanNum(rvol), 'ext': cleanNum(ext), 'q': quality, 'htf': htfAgree, 'btc': btc,
        'regime': regime, 'inds': inds, 'amt': amount, 'path': path,
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
      regime: '${j['regime'] ?? ''}', inds: '${j['inds'] ?? ''}', amount: (j['amt'] as num?)?.toDouble() ?? 0, path: '${j['path'] ?? ''}',
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
  int n = 0, wins = 0, tp = 0, sl = 0, timeouts = 0, manual = 0;
  double sumR = 0, grossWin = 0, grossLoss = 0;
  PStats(Iterable<AppTrade> list) {
    for (final t in list.where((x) => !x.isOpen)) {
      n++;
      sumR += t.r;
      if (t.r > 0) { wins++; grossWin += t.r; } else { grossLoss += -t.r; }
      if (t.reason == 'TP') tp++;
      if (t.reason == 'SL') sl++;
      if (t.reason == 'TIMEOUT') timeouts++;
      if (t.reason == 'MANUAL') manual++;
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
    'quality', 'htf_agree', 'rvol', 'ext_atr', 'btc_regime', 'market_regime', 'agreeing_indicators', 'amount_usd', 'r_path'];
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
      t.quality, t.htfAgree, r(t.rvol, 2), r(t.ext, 2), t.btc, t.regime, t.inds, r(t.notional, 2), t.path,
    ];
    lines.add(row.map(csvCell).join(','));
  }
  return lines.join('\n') + '\n';
}

String stratLabel(AppTrade t) => t.source == 'auto' ? 'Trend (auto)' : t.source == 'MR' ? 'Mean reversion (MR)'
    : t.source == 'BOT' ? 'Bot: ${t.verdict}' : t.source == 'NEWS' ? 'News headline' : 'Manual';

/// Minimal CSV parser (quoted fields, commas and line breaks inside quotes).
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final f = StringBuffer();
  var q = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (q) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') { f.write('"'); i++; } else { q = false; }
      } else {
        f.write(ch);
      }
    } else if (ch == '"') {
      q = true;
    } else if (ch == ',') {
      row.add(f.toString()); f.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(f.toString()); f.clear();
      if (row.length > 1 || row.first.isNotEmpty) rows.add(row);
      row = <String>[];
    } else {
      f.write(ch);
    }
  }
  if (f.isNotEmpty || row.isNotEmpty) { row.add(f.toString()); rows.add(row); }
  return rows;
}

/// Track record of one group of the GitHub bot's closed paper trades.
class BotRec {
  int n = 0, wins = 0;
  double sumR = 0, gw = 0, gl = 0;
  void add(double r) { n++; sumR += r; if (r > 0) { wins++; gw += r; } else { gl += -r; } }
  double get pf => gl == 0 ? (gw > 0 ? 99.0 : 0.0) : gw / gl;
  double get winPct => n == 0 ? 0 : 100.0 * wins / n;
  String get text => '$n trades, ${winPct.toStringAsFixed(0)}% wins, ${sumR >= 0 ? '+' : ''}${sumR.toStringAsFixed(1)}R, PF ${pf.toStringAsFixed(2)}';
}

// ---- GitHub files with a backup route ----
// Some networks cannot reach raw.githubusercontent.com (seen Nov 11: "Failed host lookup", "Connection reset").
// Then the same file is read through the GitHub API (api.github.com). Without a login the API allows 60 requests an
// hour, so each file is read that way at most every 2 minutes and the last copy is reused in between.
DateTime? _rawDownAt;
final Map<String, DateTime> _apiLast = {};
final Map<String, http.Response> _apiCache = {};
bool ghViaApi = false;   // true while files come through the backup route

Future<http.Response> ghGet(String rawUrl, {Duration timeout = const Duration(seconds: 30)}) async {
  final u = Uri.parse(rawUrl);
  final now = DateTime.now();
  final isRaw = u.host == 'raw.githubusercontent.com' && u.pathSegments.length >= 4;
  Object? rawErr;
  final skipRaw = isRaw && _rawDownAt != null && now.difference(_rawDownAt!).inMinutes < 5;
  if (!skipRaw) {
    try {
      final r = await http.get(u.replace(queryParameters: {'t': '${now.millisecondsSinceEpoch}'})).timeout(timeout);
      if (r.statusCode == 200 || r.statusCode == 404 || !isRaw) {
        if (r.statusCode == 200) { _rawDownAt = null; ghViaApi = false; }
        return r;
      }
      rawErr = 'HTTP ${r.statusCode}';
    } catch (e) {
      if (!isRaw) rethrow;
      rawErr = e;
    }
    _rawDownAt = now;
  }
  final key = u.path;
  final last = _apiLast[key], cached = _apiCache[key];
  if (last != null && cached != null && now.difference(last).inSeconds < 120) return cached;
  _apiLast[key] = now;
  final sg = u.pathSegments;              // owner, repo, branch, file path...
  final api = Uri.https('api.github.com', '/repos/${sg[0]}/${sg[1]}/contents/${sg.sublist(3).join('/')}', {'ref': sg[2]});
  http.Response r;
  try {
    r = await http.get(api, headers: {'Accept': 'application/vnd.github.raw', 'User-Agent': 'signal-bot-app'}).timeout(timeout);
  } catch (e) {
    if (cached != null) return cached;
    throw rawErr ?? e;
  }
  if (r.statusCode == 200) { _apiCache[key] = r; ghViaApi = true; return r; }
  if (cached != null) return cached;
  if (r.statusCode == 403 || r.statusCode == 429) throw 'GitHub backup route is busy (hourly limit reached). It retries automatically.';
  return r;
}

/// Short message for network errors instead of the raw exception text.
String netMsg(Object e) {
  final t = '$e';
  if (t.contains('Failed host lookup') || t.contains('Connection reset') || t.contains('SocketException') || t.contains('HandshakeException')) {
    return 'This network cannot reach GitHub right now (raw.githubusercontent.com and api.github.com). '
        'Try mobile data or another Wi-Fi, or set Private DNS to dns.google (Settings > Network > Private DNS).';
  }
  return t;
}

/// One row of the GitHub bot's paper log.
class BotTrade {
  final String key, sym, side, strat, tf, status;
  final DateTime opened;
  final DateTime? closed;
  final double? r;
  BotTrade(this.key, this.sym, this.side, this.strat, this.tf, this.status, this.opened, this.closed, this.r);
}

/// Focus rule, tested walk-forward on 2,201 closed bot trades (Oct 30 - Nov 9): a signal counts only when its
/// strategy + direction already has 30+ closed bot trades with a net profit. All trades -70.8R, focus trades +81.4R
/// (PF 1.21, positive in both halves). Held for thresholds 25 to 50. Uses the bot's own stop and target.
const botFocusMinN = 30;
bool botRecFocus(BotRec? r) => r != null && r.n >= botFocusMinN && r.sumR > 0;

/// Bot symbol to Binance coin: 'WLD-USDT' -> 'WLD', 'BTC-USD' -> 'BTC'. Forex / Yahoo futures return null.
String? botCoin(String sym) {
  if (sym.contains('=')) return null;
  final i = sym.indexOf('-');
  final c = i > 0 ? sym.substring(0, i) : sym;
  return futSymbols.containsKey(c) ? c : null;
}

/// Profit breakdown, one row per (dimension, key): which coins, timeframes, indicators, sides, hours and regimes make money.
/// Only closed trades count; results are net of the paper fee. Rows with fewer than 10 trades are labelled "too few trades".
/// The indicator rows use the indicators that AGREED with the trade direction at entry (the "agreeing_indicators" column).
/// Edge of one group of closed trades (manual closes left out), judged on two time halves
/// so one lucky streak is not mistaken for an edge.
const focusMinN = 15;
class Edge {
  final int n;
  final double sumR, pf, winPct, r1, r2, a1, a2;   // net R of the older / newer half, and their average R per trade
  Edge(this.n, this.sumR, this.pf, this.winPct, this.r1, this.r2, this.a1, this.a2);
  double get avgR => n == 0 ? 0 : sumR / n;
  bool get proven => n >= focusMinN && pf > 1.1 && r1 > 0 && r2 > 0;
  bool get losing => n >= focusMinN && r1 < 0 && r2 < 0;
  String get verdict => n < focusMinN ? 'too few trades' : proven ? 'PROVEN (both halves)' : losing ? 'LOSING (both halves)'
      : sumR > 0 ? 'profitable, not consistent' : 'mixed';
}
List<AppTrade> edgeSample(Iterable<AppTrade> all) => all.where((t) => !t.isOpen && t.reason != 'MANUAL' && t.source != 'NEWS').toList();
Edge edgeOf(List<AppTrade> g) {
  final s = [...g]..sort((a, b) => a.opened.compareTo(b.opened));
  final st = PStats(s);
  final h = s.length ~/ 2;
  double sr(Iterable<AppTrade> x) => x.fold(0.0, (a, t) => a + t.r);
  final r1 = sr(s.take(h)), r2 = sr(s.skip(h));
  return Edge(st.n, st.sumR, st.pf, st.winPct, r1, r2, h == 0 ? 0.0 : r1 / h, s.length - h == 0 ? 0.0 : r2 / (s.length - h));
}
/// Indicators agree on most trades, so on their own they only mirror the overall result. An indicator counts as
/// better (1) or worse (-1) only when both halves beat / trail the average trade of that direction by 0.1 R.
int indicatorRel(Edge e, Edge? base) {
  if (base == null || e.n < focusMinN) return 0;
  if (e.r1 > 0 && e.r2 > 0 && e.pf > 1.1 && e.a1 > base.avgR + 0.1 && e.a2 > base.avgR + 0.1) return 1;
  if (e.r1 < 0 && e.r2 < 0 && e.a1 < base.avgR - 0.1 && e.a2 < base.avgR - 0.1) return -1;
  return 0;
}
/// Groups used by the Focus filter: 'c|COIN|BUY' (coin + direction), 'i|INDICATOR|BUY' (indicator + direction), 's|BUY' (all of a direction).
Map<String, Edge> focusEdges(Iterable<AppTrade> all) {
  final g = <String, List<AppTrade>>{};
  for (final t in edgeSample(all)) {
    final sd = t.side == 1 ? 'BUY' : 'SELL';
    g.putIfAbsent('c|${t.coin}|$sd', () => []).add(t);
    g.putIfAbsent('s|$sd', () => []).add(t);
    for (final ind in t.inds.split('|')) {
      if (ind.isNotEmpty) g.putIfAbsent('i|$ind|$sd', () => []).add(t);
    }
  }
  return {for (final e in g.entries) e.key: edgeOf(e.value)};
}

String profitAnalysisCsv(List<AppTrade> all) {
  final closed = edgeSample(all);   // manual closes are left out: they are your decision, not the signal's
  final groups = <String, Map<String, List<AppTrade>>>{};
  void add(String dim, String key, AppTrade t) {
    if (key.isEmpty) return;
    final m = groups.putIfAbsent(dim, () => <String, List<AppTrade>>{});
    m.putIfAbsent(key, () => <AppTrade>[]).add(t);
  }
  for (final t in closed) {
    final side = t.side == 1 ? 'BUY' : 'SELL';
    final adx = t.adx;
    add('strategy', stratLabel(t), t);
    add('timeframe', t.tf, t);
    add('side', side, t);
    add('coin', t.coin, t);
    add('coin+timeframe', '${t.coin} ${t.tf}', t);
    add('coin+side', '${t.coin} $side', t);
    add('coin+side+timeframe', '${t.coin} $side ${t.tf}', t);
    add('hour_utc', t.opened.toUtc().hour.toString().padLeft(2, '0'), t);
    add('score_band', t.score.abs() >= .5 ? 'strong 0.5+' : t.score.abs() >= .35 ? 'medium 0.35-0.5' : 'weak 0.2-0.35', t);
    add('adx_band', adx == null ? '' : adx < 20 ? 'ADX under 20' : adx < 25 ? 'ADX 20-25' : 'ADX 25+', t);
    add('regime', t.regime, t);
    for (final ind in t.inds.split('|')) {
      if (ind.isEmpty) continue;
      add('indicator', ind, t);
      add('indicator+timeframe', '$ind ${t.tf}', t);
      add('indicator+side', '$ind $side', t);
      add('coin+side+indicator', '${t.coin} $side $ind', t);
    }
  }
  const cols = ['dimension', 'key', 'trades', 'wins', 'losses', 'win_rate_pct', 'net_r', 'avg_r', 'profit_factor', 'pnl_usd',
    'avg_mfe_r', 'avg_mae_r', 'tp_hits', 'sl_hits', 'first_half_r', 'second_half_r', 'verdict'];
  final lines = <String>[cols.join(',')];
  for (final dim in groups.keys) {
    final entries = groups[dim]!.entries.toList()
      ..sort((a, b) => PStats(b.value).sumR.compareTo(PStats(a.value).sumR));
    for (final e in entries) {
      final st = PStats(e.value);
      var pnl = 0.0, mfe = 0.0, mae = 0.0;
      for (final t in e.value) {
        pnl += t.pnl;
        mfe += t.mfe;
        mae += t.mae;
      }
      final n = e.value.length;
      final ed = edgeOf(e.value);
      lines.add([dim, e.key, st.n, st.wins, st.n - st.wins, st.winPct.toStringAsFixed(1), st.sumR.toStringAsFixed(2),
        st.avgR.toStringAsFixed(3), st.pf.toStringAsFixed(2), pnl.toStringAsFixed(2), (mfe / n).toStringAsFixed(2),
        (mae / n).toStringAsFixed(2), st.tp, st.sl, ed.r1.toStringAsFixed(2), ed.r2.toStringAsFixed(2), ed.verdict].map(csvCell).join(','));
    }
  }
  return lines.join('\n') + '\n';
}

/// One row per closed trade and agreeing indicator (long format), for pivot tables: indicator x timeframe x coin x result.
String tradeIndicatorsCsv(List<AppTrade> all) {
  const cols = ['trade_id', 'opened_utc', 'symbol', 'timeframe', 'side', 'strategy', 'regime', 'indicator', 'r_multiple', 'win',
    'exit_reason', 'score', 'adx', 'hour_utc'];
  final lines = <String>[cols.join(',')];
  for (final t in all.where((x) => !x.isOpen)) {
    final adx = t.adx;
    for (final ind in t.inds.split('|')) {
      if (ind.isEmpty) continue;
      lines.add([t.id, t.opened.toUtc().toIso8601String(), t.coin, t.tf, t.side == 1 ? 'BUY' : 'SELL', stratLabel(t), t.regime,
        ind, t.r.toStringAsFixed(3), t.r > 0 ? 1 : 0, t.reason, t.score.toStringAsFixed(3),
        adx == null ? '' : adx.toStringAsFixed(1), t.opened.toUtc().hour].map(csvCell).join(','));
    }
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
const labFee = 0.05;            // same paper fee as everywhere else, in R
/// The only indicators the Lab records (your choice, Nov 10: 7 first, then RSI (14), Z-score (20) and Ultimate Oscillator). Everything else was removed from the Lab.
/// The Experiments tab (GitHub) still tests 40 indicators, so they can be compared there.
const labBase = ['RSI (2)', 'RSI (14)', 'CCI (20)', 'Stochastic (14,3)', 'Stochastic RSI', 'MFI (14)', 'Bollinger %B (20,2)', 'Z-score (20)',
  'Ultimate Oscillator', 'Candle pattern'];
/// Each Lab indicator also has a "+ trend" version (Nov 10): BUY only while price is above EMA 200 of the same timeframe,
/// SELL only while it is below. The first day showed these signals winning on SELL and losing on BUY in a falling market.
const labTrendSuffix = ' + trend';
final labKeep = <String>[...labBase, for (final n in labBase) '$n$labTrendSuffix'];

/// One Lab signal seen as a trade: entry at the signal candle's close, target and stop 1.5 ATR (1:1), judged over 6 candles.
class LabTrade {
  final LabSnap s;
  final int side;
  final bool open;
  LabTrade(this.s, this.side, this.open);
  String get result => open ? 'OPEN' : s.race == side ? 'WIN' : s.race == -side ? 'LOSS' : 'TIMEOUT';
  double get r => open ? 0 : s.race == side ? 1 - labFee : s.race == -side ? -1 - labFee
      : (s.move * side / labRaceAtr).clamp(-1.0, 1.0).toDouble() - labFee;
  double get tp => s.price + side * labRaceAtr * s.atr;
  double get sl => s.price - side * labRaceAtr * s.atr;
}

class LabStat {
  int n = 0, w = 0, l = 0, t = 0, open = 0;
  double r = 0;
  void add(LabTrade x) {
    if (x.open) { open++; return; }
    n++;
    r += x.r;
    if (x.result == 'WIN') { w++; } else if (x.result == 'LOSS') { l++; } else { t++; }
  }
  double? get winPct => w + l == 0 ? null : 100.0 * w / (w + l);
  String get text => '$n trades: $w won, $l lost, $t timed out${winPct == null ? '' : ', ${winPct!.toStringAsFixed(0)}% of decided'}, '
      '${r >= 0 ? '+' : ''}${r.toStringAsFixed(1)}R${open > 0 ? ', $open open' : ''}';
}

String labTradesCsv(List<LabTrade> list) {
  final lines = ['time_utc,coin,tf,style,side,entry,target,stop,atr,result,r_multiple,move_atr_at_horizon'];
  for (final x in list) {
    lines.add([x.s.t0.toUtc().toIso8601String(), x.s.coin, x.s.tf, styleOf(x.s.tf), x.side == 1 ? 'BUY' : 'SELL', x.s.price, x.tp, x.sl, x.s.atr,
      x.result, x.open ? '' : x.r.toStringAsFixed(3), x.open ? '' : x.s.move.toStringAsFixed(3)].join(','));
  }
  return lines.join('\n') + '\n';
}

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
  final Map<String, List<Candle>> chartOlder = {};   // candles older than the live 300, loaded while scrolling back
  final Set<String> chartNoMore = {};                // coin|timeframe with no older history left
  double chartOffset = 0;                             // candles between the right edge of the chart and the newest candle
  int chartCount = 80;                                // candles on screen
  String chartKey = '';
  bool chartBusy = false;
  AppTrade? chartTrade;                               // trade whose entry, stop and target are drawn (open or closed)
  List<ChartMark> chartExtra = [];                    // levels of a tapped bot signal or Lab trade
  String chartExtraCoin = '';
  DateTime? chartJump;                                // time to bring into view after loading
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
  Map<String, BotRec> botRec = {};      // 'strategy|SIDE' and 'symbol|SIDE' -> bot track record
  DateTime? botRecAt;
  String? botRecError;
  Timer? botRecTimer;
  BotRec botFocusAcc = BotRec(), botFocusToday = BotRec();   // bot trades that were focus when they opened (runs on GitHub)
  int botFocusOpen = 0;
  List<BotTrade> botFocusRecent = [], botFocusAll = [];
  Map<String, dynamic>? expData;                                // Experiment lab summary (exp-data branch)
  String? expError;
  DateTime? expAt;
  Timer? expTimer;
  String expView = 'I', expTf = 'All';
  int expTarget = 1, expMinN = 20;
  bool expProvenOnly = false, expWorst = false;
  bool newsAuto = true;                 // auto paper trades from news headlines, on all 6 timeframes
  final Set<String> newsSeen = {};
  bool newsTradeBusy = false;
  String newsTradeStatus = '';
  bool allLogsBusy = false;
  int paperSource = 1;                  // 0 = app indicators, 1 = bot focus signals, 2 = both
  bool sigFocusOnly = true;             // Signals tab: show only focus signals
  final Set<String> botSeen = {};       // bot signals already handled
  bool botFollowBusy = false;
  String botStatus = '';
  int focusSkipped = 0;   // signals the Focus filter skipped this session
  int focusMode = 0;   // 0 off, 1 skip coin/direction/indicator combos that lost in both halves, 2 only proven combos
  int _focusKey = -1;
  Map<String, Edge> _focusEdges = {};
  int paperMaxOpen = 1000000, paperMinQ = 4, paperRejected = 0, paperCoins = 20, paperMinAdx = 25;
  Set<String> paperTfs = {'5m', '1h', '4h'};
  bool paperScanBusy = false;
  final Map<String, int> paperLogged = {};     // coin|tf -> candle close already handled
  List<String> paperCoinList = [];
  DateTime paperCoinsAt = DateTime(2000);
  String paperStatus = '';
  final Map<String, LiveQuote> liveQuotes = {};   // coin -> latest bid/ask
  DateTime? liveAt;
  bool liveBusy = false;
  Timer? liveTimer;
  final List<GateReject> gateRejects = [];        // most recent signals the gate turned into NO TRADE
  final Map<String, String> gateLast = {};        // coin|tf -> 'hh:mm|OK' or 'hh:mm|reason'
  AppTrade? focusTrade;                           // trade selected in the Paper tab, drawn on the Markets chart
  String ofSide = 'All', ofTf = 'All', ofPnl = 'All', ofSort = 'Newest';   // filters of the live open-trades table
  final TextEditingController ofCoinCtl = TextEditingController();
  bool paperMr = false;                            // mean-reversion BUY strategy on/off
  DateTime lastPathSave = DateTime.now();
  double paperAmount = 0;                         // USD per paper trade typed in Settings; 0 = risk 1% of the account
  final TextEditingController paperAmountCtl = TextEditingController();
  final TextEditingController rrCtl = TextEditingController();
  int paperSignals = 0;                           // signals that passed the score/ADX pre-filter this session
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
  String labStyle = 'All', labCat = 'All', labStatus = '', labSide = 'All';
  String? labSel;          // indicator whose trades are shown
  String labVersion = 'All';   // All / Plain / With trend
  int labShown = 50;
  DateTime? labUpdated;
  Timer? labTimer, uiTimer;
  final ValueNotifier<int> liveTick = ValueNotifier<int>(0);   // redraws only the live trades table every second when there are many trades
  int uiTick = 0;
  int openShown = 30;                                          // rows of the live table shown (Show more adds 30)
  final Map<String, DateTime> paperCheckedAt = {};

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 30), (_) => load(silent: true));
    loadBotRec();
    botRecTimer = Timer.periodic(const Duration(minutes: 10), (_) => loadBotRec());
    loadExp();
    expTimer = Timer.periodic(const Duration(minutes: 10), (_) => loadExp());
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
    paperTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      checkPaper();
      followBotSignals();
      paperScanCycle();
    });
    uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      uiTick++;
      if (!mounted) return;
      if (trades.length <= 60 || uiTick % 5 == 0) {
        setState(() {});                 // refresh every tab each second (every 5 s with many trades, to keep the app fast)
      } else {
        liveTick.value = uiTick;         // only the live table
      }
    });
    liveTimer = Timer.periodic(const Duration(seconds: 3), (_) => refreshLive());                    // current rates for open paper trades
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
    botRecTimer?.cancel();
    expTimer?.cancel();
    labTimer?.cancel();
    uiTimer?.cancel();
    liveTick.dispose();
    liveTimer?.cancel();
    paperAmountCtl.dispose();
    rrCtl.dispose();
    ofCoinCtl.dispose();
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
        // keep only the Lab indicators (older data had about 50)
        labAgg.removeWhere((k, _) => !labKeep.contains(k.substring(0, k.lastIndexOf('|'))));
        for (final sn in [...labPending, ...labRows]) {
          sn.votes.removeWhere((k, _) => !labKeep.contains(k));
        }
        labPending.removeWhere((sn) => sn.votes.isEmpty);
        labRows.removeWhere((sn) => sn.votes.isEmpty);
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
    if (labRows.length > 6000) labRows = labRows.sublist(labRows.length - 6000);   // 10 indicators per row now, so more rows fit
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
            var trend = 0;                                   // +1 price above EMA 200, -1 below, 0 not enough candles
            for (final r in a.ma) {
              if (r.name == 'EMA 200') trend = r.sig;
            }
            for (final r in [...a.ma, ...a.osc]) {
              if (r.sig != 0 && labBase.contains(r.name)) {
                votes[r.name] = r.sig;
                if (trend == r.sig) votes['${r.name}$labTrendSuffix'] = r.sig;
              }
            }
            return LabSnap(j[0], j[1], t0, closed.last.close, a.atr, votes)..move = t0.millisecondsSinceEpoch.toDouble();
          } catch (_) {
            return null;
          }
        }));
        for (final sn in res.whereType<LabSnap>()) {
          labLogged['${sn.coin}|${sn.tf}'] = sn.move.toInt();     // temporarily carried the candle time here
          sn.move = 0;
          if (sn.votes.isEmpty) continue;                          // none of the Lab indicators signalled on this candle
          labPending.add(sn);
          added++;
        }
      }
      labUpdated = DateTime.now();
      labStatus = 'Last run: $added candles with a signal from the ${labKeep.length} Lab indicators, ${labPending.length} waiting to be scored, $labScored scored in total.';
      await saveLab();
    } catch (e) {
      labStatus = 'Lab could not run: $e';
    } finally {
      labBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> downloadLabAcc() async {
    if (labAgg.isEmpty) return toast('Nothing scored yet. The first results appear about ${labHorizonBars} candles after the first signals.');
    await downloadCsv('lab_indicator_accuracy.csv', labAggCsv(labAgg));
  }

  Future<void> downloadLabRows() async {
    if (labRows.isEmpty) return toast('Nothing scored yet.');
    await downloadCsv('lab_signal_snapshots.csv', labRowsCsv(labRows));
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
      paperMaxOpen = p.getInt('app_paper_max') ?? 1000000;
      paperAmount = p.getDouble('app_paper_amount') ?? 0;
      paperMr = p.getBool('app_paper_mr') ?? false;
      focusMode = (p.getInt('app_paper_focus') ?? 0).clamp(0, 2).toInt();
      paperSource = (p.getInt('app_paper_src') ?? 1).clamp(0, 2).toInt();   // new installs and updates start on bot focus signals
      sigFocusOnly = p.getBool('app_sig_focus') ?? true;
      newsAuto = p.getBool('app_news_auto') ?? true;
      newsSeen..clear()..addAll(p.getStringList('app_news_seen') ?? const <String>[]);
      botSeen..clear()..addAll(p.getStringList('app_bot_seen') ?? const <String>[]);
      planRR = p.getDouble('app_paper_rr') ?? 1.0;
      if (planRR.isNaN || planRR < 0.5 || planRR > 10) planRR = 1.0;
      rrCtl.text = const [1.0, 1.5, 2.0].contains(planRR) ? '' : fmtRR(planRR);
      if (!(p.getBool('app_paper_v7') ?? false)) {
        paperMr = false;      // mean reversion lost in your backtest (-7.6R, 20 trades) and in paper (-7.6R, 26 trades): off until proven; switch it back on if you want
        await p.setBool('app_paper_v7', true);
      }
      paperAmountCtl.text = paperAmount > 0 ? paperAmount.toStringAsFixed(paperAmount == paperAmount.roundToDouble() ? 0 : 2) : '';
      paperCoins = p.getInt('app_paper_coins') ?? 20;
      final tl = p.getStringList('app_paper_tfs');
      if (tl != null && tl.isNotEmpty) paperTfs = tl.toSet();
      paperMinQ = p.getInt('app_paper_q') ?? 4;
      paperMinAdx = p.getInt('app_paper_adx') ?? 25;
      if (!(p.getBool('app_paper_v6') ?? false)) {
        paperTfs.remove('15m');                       // 15m lost in three data sets in a row (about 29% wins over 28 trades); you can switch it back on
        if (paperTfs.isEmpty) paperTfs = {'5m'};
        await p.setBool('app_paper_v6', true);
        await p.setStringList('app_paper_tfs', paperTfs.toList());
      }
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
      if (!(p.getBool('app_paper_v4') ?? false)) {
        paperMaxOpen = 1000000;                       // no limit on open paper trades
        await p.setBool('app_paper_v4', true);
        await p.setInt('app_paper_max', paperMaxOpen);
      }
    } catch (_) {}
    paperLoaded = true;
    if (autoPaper) setBackgroundService(true);
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
      await p.setDouble('app_paper_amount', paperAmount);
      await p.setBool('app_paper_mr', paperMr);
      await p.setInt('app_paper_focus', focusMode);
      await p.setInt('app_paper_src', paperSource);
      await p.setBool('app_sig_focus', sigFocusOnly);
      await p.setBool('app_news_auto', newsAuto);
      await p.setStringList('app_news_seen', newsSeen.toList().reversed.take(500).toList().reversed.toList());
      await p.setStringList('app_bot_seen', botSeen.toList().reversed.take(400).toList().reversed.toList());
      await p.setDouble('app_paper_rr', planRR);
      await p.setInt('app_paper_q', paperMinQ);
      await p.setInt('app_paper_adx', paperMinAdx);
      await p.setInt('app_paper_coins', paperCoins);
      await p.setStringList('app_paper_tfs', paperTfs.toList());
    } catch (_) {}
  }

  double get paperEquity => paperStart + trades.where((t) => !t.isOpen).fold(0.0, (a, t) => a + t.pnl);

  /// Downloads the GitHub bot's paper log and builds its track record per strategy + direction and coin + direction.
  Future<void> loadBotRec() async {
    if (feedUrl.isEmpty) return;
    try {
      if (botRec.isEmpty) await loadBotRecSaved();
      final url = feedUrl.replaceAll('feed.json', 'paper_log.csv');
      final r = await ghGet(url);
      if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
      final rows = parseCsv(utf8.decode(r.bodyBytes));
      if (rows.isEmpty) throw 'empty file';
      final h = rows.first;
      final iS = h.indexOf('strategy'), iSide = h.indexOf('side'), iSym = h.indexOf('symbol'), iSt = h.indexOf('status'), iR = h.indexOf('r_multiple');
      final iO = h.indexOf('opened_utc'), iC = h.indexOf('closed_utc'), iTf = h.indexOf('tf');
      if (iS < 0 || iSide < 0 || iSym < 0 || iSt < 0 || iR < 0) throw 'unexpected columns';
      // focus account: replay the log in time order and keep the trades that were focus when they opened
      if (iO >= 0 && iC >= 0) {
        final all = <BotTrade>[];
        for (final row in rows.skip(1)) {
          if (row.length <= math.max(iR, math.max(iO, iC))) continue;
          final o = DateTime.tryParse(row[iO]);
          if (o == null) continue;
          all.add(BotTrade('${row[iS]}|${row[iSide]}', row[iSym], row[iSide], row[iS], iTf >= 0 ? row[iTf] : '', row[iSt], o,
              DateTime.tryParse(row[iC]), double.tryParse(row[iR])));
        }
        final byOpen = [...all]..sort((a, b) => a.opened.compareTo(b.opened));
        final done = all.where((t) => t.status == 'closed' && t.closed != null && t.r != null).toList()
          ..sort((a, b) => a.closed!.compareTo(b.closed!));
        final run = <String, BotRec>{};
        final acc = BotRec(), today = BotRec(), recent = <BotTrade>[];
        final day = DateTime.now().toUtc();
        var j = 0, openN = 0;
        for (final t in byOpen) {
          while (j < done.length && done[j].closed!.isBefore(t.opened)) {
            run.putIfAbsent(done[j].key, () => BotRec()).add(done[j].r!);
            j++;
          }
          if (!botRecFocus(run[t.key])) continue;
          recent.add(t);
          if (t.status == 'closed' && t.r != null) {
            acc.add(t.r!);
            final c = t.closed?.toUtc();
            if (c != null && c.year == day.year && c.month == day.month && c.day == day.day) today.add(t.r!);
          } else if (t.status == 'open') {
            openN++;
          }
        }
        botFocusAcc = acc;
        botFocusToday = today;
        botFocusOpen = openN;
        botFocusRecent = recent.reversed.take(15).toList();
        botFocusAll = recent;
      }
      final m = <String, BotRec>{};
      for (final row in rows.skip(1)) {
        if (row.length <= iR || row[iSt] != 'closed') continue;
        final rr = double.tryParse(row[iR]);
        if (rr == null) continue;
        m.putIfAbsent('${row[iS]}|${row[iSide]}', () => BotRec()).add(rr);
        m.putIfAbsent('sym:${row[iSym]}|${row[iSide]}', () => BotRec()).add(rr);
        m.putIfAbsent('side:${row[iSide]}', () => BotRec()).add(rr);
        m.putIfAbsent('all', () => BotRec()).add(rr);
      }
      botRec = m;
      botRecAt = DateTime.now();
      botRecError = null;
      saveBotRec();
    } catch (e) {
      botRecError = botRec.isEmpty ? 'Bot track record could not load. ${netMsg(e)}'
          : 'Could not refresh the bot record, using the copy from ${botRecAt == null ? '-' : hhmm(botRecAt!)}. ${netMsg(e)}';
    }
    if (mounted) setState(() {});
  }

  String? expUrl() {
    final u = Uri.tryParse(feedUrl);
    if (feedUrl.isEmpty || u == null || u.pathSegments.length < 3) return null;
    return Uri.https(u.host, '/${u.pathSegments[0]}/${u.pathSegments[1]}/exp-data/exp_summary.json').toString();
  }

  Future<void> loadExp() async {
    final url = expUrl();
    if (url == null) {
      expError = 'FEED_URL was not set when the app was built.';
      return;
    }
    try {
      final r = await ghGet(url);
      if (r.statusCode == 404) {
        throw 'No experiment data yet. Add experiments.py and .github/workflows/experiments.yml to your repo, then open GitHub > Actions > '
            '"Experiment lab" > Run workflow. Results appear here about 3 minutes later.';
      }
      if (r.statusCode != 200) throw 'Could not load experiment results (HTTP ${r.statusCode}).';
      expData = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      expAt = DateTime.now();
      expError = null;
    } catch (e) {
      expError = expData == null ? netMsg(e) : 'Could not refresh, showing the copy from ${expAt == null ? '-' : hhmm(expAt!)}. ${netMsg(e)}';
    }
    if (mounted) setState(() {});
  }

  Widget botFocusCard() {
    if (botRec.isEmpty) return const SizedBox.shrink();
    final a = botFocusAcc, td = botFocusToday;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Bot focus account (runs on GitHub 24/7, phone can be off)', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          const Text('Bot paper trades that were FOCUS at the moment they opened (same rule as the Signals tab). Nothing here needs the app open.',
              style: TextStyle(fontSize: 11)),
          const SizedBox(height: 6),
          Text('Closed: ${a.n == 0 ? 'none yet' : a.text}', style: TextStyle(fontWeight: FontWeight.w600, color: a.sumR >= 0 ? Colors.green : Colors.red)),
          Text('Closed today (UTC): ${td.n == 0 ? 'none' : td.text}', style: const TextStyle(fontSize: 12)),
          Text('Open now: $botFocusOpen', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          for (final t in botFocusRecent.take(10))
            Text('${t.side} ${t.sym}  ${t.strat} ${t.tf}  ${t.status == 'open' ? 'open' : '${(t.r ?? 0) >= 0 ? '+' : ''}${(t.r ?? 0).toStringAsFixed(2)}R'}  ${ago(t.opened.toIso8601String())}',
                style: TextStyle(fontSize: 11, color: t.status == 'open' ? null : (t.r ?? 0) >= 0 ? Colors.green : Colors.red)),
        ]),
      ),
    );
  }

  Widget expTab() {
    final d = expData;
    if (d == null) {
      return RefreshIndicator(
        onRefresh: loadExp,
        child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(16), children: [
          const Text('Experiment lab', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 8),
          Text(expError ?? 'Loading experiment results...'),
        ]),
      );
    }
    final rows = (d['rows'] as Map? ?? {}).cast<String, dynamic>();
    final minN = (d['min_n'] as num?)?.toInt() ?? 50;
    final o = expTarget == 1 ? 0 : 5;                 // row: n, win, R, pf, older R, newer R (1:1), then the same for 1:2
    List<num> v(String k) => (rows[k] as List).cast<num>();
    bool proven(List<num> a) => a[0] >= minN && a[3 + o] > 1.1 && a[4 + o] > 0 && a[5 + o] > 0;
    bool losing(List<num> a) => a[0] >= minN && a[4 + o] < 0 && a[5 + o] < 0;
    String label(String k) {
      final p = k.split('|');
      switch (p[0]) {
        case 'i': return '${p[1]} ${p[3]} (${p[2]})';
        case 'l': return '${p[1]} ${p[3]} (${p[2]})';
        case 'ic': return '${p[1]} ${p[2]} on ${p[3]}';
        default: return p.length >= 3 ? '${p[1]} ${p[2]}' : k;
      }
    }
    final keys = rows.keys.where((k) {
      if (!k.startsWith('$expView|')) return false;
      final a = v(k);
      if (a[0] < expMinN) return false;
      if (expProvenOnly && !proven(a)) return false;
      if (expTf != 'All' && (expView == 'i' || expView == 'l' || expView == 't') && k.split('|')[expView == 't' ? 1 : 2] != expTf) return false;
      return true;
    }).toList()
      ..sort((x, y) => expWorst ? v(x)[2 + o].compareTo(v(y)[2 + o]) : v(y)[2 + o].compareTo(v(x)[2 + o]));
    final all = rows['all'] == null ? null : v('all');
    final provenN = rows.keys.where((k) => k.startsWith('$expView|') && proven(v(k))).length;
    Color rc(num x) => x >= 0 ? Colors.green : Colors.red;
    String sg(num x) => '${x >= 0 ? '+' : ''}${x.toStringAsFixed(1)}';
    final tfs = ((d['tfs'] as List?) ?? const []).map((e) => '$e').toList();
    return RefreshIndicator(
      onRefresh: loadExp,
      child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(12), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Experiment lab (runs on GitHub every 10 minutes, phone can be off)', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              Text('Updated ${ago('${d['updated']}')}. ${(d['coins'] as List?)?.length ?? 0} coins x ${tfs.join(', ')}. '
                  'Open trades ${d['open']}, closed ${d['closed']}${(d['days'] as List?)?.length == 2 ? ', ${(d['days'] as List)[0]} to ${(d['days'] as List)[1]}' : ''}.',
                  style: const TextStyle(fontSize: 12)),
              if (all != null)
                Text('All experiments at 1:${expTarget}: ${all[0]} trades, ${all[1 + o]}% wins, ${sg(all[2 + o])}R, PF ${all[3 + o]}',
                    style: TextStyle(fontWeight: FontWeight.w600, color: rc(all[2 + o]))),
              const SizedBox(height: 4),
              Builder(builder: (_) {
                final run = (d['run'] as Map?) ?? const {};
                final nc = (run['news_coins'] as List?) ?? const [];
                final fd = (run['news_feeds'] as Map?) ?? const {};
                return Text('${nc.isEmpty ? '"News headline": no new coin headline in the last run.' : '"News headline" last run: ${nc.join(', ')}'}'
                    '${fd.isEmpty ? '' : '\nNews feeds from GitHub: ${fd.entries.map((e) => '${e.key} ${e.value}').join(', ')}'}',
                    style: const TextStyle(fontSize: 11));
              }),
              const SizedBox(height: 4),
              zipButton(),
              Text('Every indicator opens a virtual trade on each new signal, on every coin and timeframe, entering at the next candle. '
                  '"News headline" trades each new coin headline from CoinDesk, Cointelegraph and Decrypt on all timeframes at the current price. '
                  'Each trade is followed to a 1:1 and a 1:2 target (stop 1.5 ATR, 0.05R fee). PROVEN = $minN+ trades, profit factor above 1.1 '
                  'and profit in both the older and the newer half. Many trades happen at the same moment on different coins, so only trust PROVEN rows.',
                  style: const TextStyle(fontSize: 11)),
            ]),
          ),
        ),
        Wrap(spacing: 6, children: [
          for (final e in const {'Indicators': 'I', 'Indicator + timeframe': 'i', 'Coins': 'c', 'Indicator + coin': 'ic', 'Timeframes': 't',
            'App Lab rules': 'L', 'App Lab rules + timeframe': 'l'}.entries)
            ChoiceChip(label: Text(e.key), selected: expView == e.value, onSelected: (_) => setState(() => expView = e.value)),
        ]),
        Wrap(spacing: 6, children: [
          for (final t in const [1, 2]) ChoiceChip(label: Text('Target 1:$t'), selected: expTarget == t, onSelected: (_) => setState(() => expTarget = t)),
          ChoiceChip(label: const Text('Best first'), selected: !expWorst, onSelected: (_) => setState(() => expWorst = false)),
          ChoiceChip(label: const Text('Worst first'), selected: expWorst, onSelected: (_) => setState(() => expWorst = true)),
          FilterChip(label: Text('Proven only ($provenN)'), selected: expProvenOnly, onSelected: (x) => setState(() => expProvenOnly = x)),
        ]),
        Wrap(spacing: 6, children: [
          for (final n in const [1, 20, 50, 100]) ChoiceChip(label: Text('$n+ trades'), selected: expMinN == n, onSelected: (_) => setState(() => expMinN = n)),
        ]),
        if (expView == 'L' || expView == 'l')
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('App Lab rules: the same 10 indicators and scoring as the Lab tab, but run on GitHub 24/7. A signal counts on every candle '
                'while the indicator is in its zone; entry at that candle\'s close, target and stop 1.5 ATR, judged over 6 candles, 0.05R fee. '
                'One result per signal, so Target 1:1 and 1:2 show the same number here.', style: TextStyle(fontSize: 11)),
          ),
        if (expView == 'i' || expView == 'l' || expView == 't')
          Wrap(spacing: 6, children: [
            for (final t in ['All', ...tfs]) ChoiceChip(label: Text(t), selected: expTf == t, onSelected: (_) => setState(() => expTf = t)),
          ]),
        if (expError != null) Text(expError!, style: const TextStyle(fontSize: 11, color: Colors.orange)),
        if (keys.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Nothing matches yet. Lower the trade minimum or wait for more data.')),
        for (final k in keys.take(60))
          Builder(builder: (_) {
            final a = v(k);
            final pv = proven(a), ls = losing(a);
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(label(k), style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${a[0]} trades, ${a[1 + o]}% wins, PF ${a[3 + o]}, halves ${sg(a[4 + o])} / ${sg(a[5 + o])}'
                  '${pv ? '  PROVEN' : ls ? '  LOSING' : ''}',
                  style: TextStyle(fontSize: 12, color: pv ? Colors.green : ls ? Colors.red : null)),
              trailing: Text('${sg(a[2 + o])}R', style: TextStyle(fontWeight: FontWeight.w700, color: rc(a[2 + o]))),
            );
          }),
        if (keys.length > 60) Text('Showing 60 of ${keys.length}.', style: const TextStyle(fontSize: 11)),
      ]),
    );
  }

  /// Saved copy of the bot record, so Focus still works when GitHub cannot be reached.
  Future<void> saveBotRec() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('app_bot_rec', jsonEncode({
        'at': botRecAt?.toIso8601String(),
        'rec': {for (final e in botRec.entries) e.key: [e.value.n, e.value.wins, e.value.sumR, e.value.gw, e.value.gl]},
      }));
    } catch (_) {}
  }

  Future<void> loadBotRecSaved() async {
    try {
      final p = await SharedPreferences.getInstance();
      final t = p.getString('app_bot_rec');
      if (t == null) return;
      final j = jsonDecode(t) as Map<String, dynamic>;
      final m = <String, BotRec>{};
      (j['rec'] as Map).forEach((k, v) {
        final a = (v as List).cast<num>();
        m['$k'] = BotRec()
          ..n = a[0].toInt()
          ..wins = a[1].toInt()
          ..sumR = a[2].toDouble()
          ..gw = a[3].toDouble()
          ..gl = a[4].toDouble();
      });
      if (m.isNotEmpty && botRec.isEmpty) {
        botRec = m;
        botRecAt = DateTime.tryParse('${j['at']}');
      }
    } catch (_) {}
  }

  BotRec? recOf(Map<String, dynamic> s) => botRec['${s['strategy']}|${s['side']}'];
  bool isFocus(Map<String, dynamic> s) => botRecFocus(recOf(s));

  /// Opens app paper trades from fresh bot signals that pass the focus rule, with the bot's own stop and target.
  Future<void> followBotSignals() async {
    if (!autoPaper || !paperLoaded || paperSource == 0 || botFollowBusy || data == null || botRec.isEmpty) return;
    final sigs = (data!['signals'] as List? ?? []).cast<Map<String, dynamic>>();
    String key(Map<String, dynamic> s) => '${s['symbol']}|${s['strategy']}|${s['tf']}|${s['side']}|${s['time']}';
    final fresh = sigs.where((s) => !botSeen.contains(key(s))).toList();
    if (fresh.isEmpty) return;
    botFollowBusy = true;
    var opened = 0, notFocus = 0, stale = 0, notCoin = 0, busy = 0, moved = 0, bad = 0;
    try {
      for (final s in fresh.reversed) {                 // oldest first
        botSeen.add(key(s));
        final t0 = DateTime.tryParse('${s['time']}');
        if (t0 == null || DateTime.now().toUtc().difference(t0.toUtc()).inMinutes > 30) { stale++; continue; }
        final side = s['side'] == 'BUY' ? 1 : -1;
        final rec = recOf(s);
        if (!botRecFocus(rec)) {
          notFocus++;
          gateRejects.insert(0, GateReject(DateTime.now(), '${s['symbol']}', '${s['tf']}', side,
              'Bot signal not focus: ${s['strategy']} ${s['side']} ${rec == null ? 'has no record yet' : rec.text}'));
          if (gateRejects.length > 60) gateRejects.removeLast();
          continue;
        }
        final coin = botCoin('${s['symbol']}');
        if (coin == null) { notCoin++; continue; }
        if (trades.any((t) => t.isOpen && t.coin == coin && t.source != 'NEWS')) { busy++; continue; }
        if (trades.where((t) => t.isOpen && (t.source == 'auto' || t.source == 'MR' || t.source == 'BOT')).length >= paperMaxOpen) { busy++; continue; }
        final sl = (s['sl'] as num?)?.toDouble(), tp = (s['tp'] as num?)?.toDouble(), e0 = (s['entry'] as num?)?.toDouble();
        if (sl == null || tp == null || e0 == null) continue;
        final px = await fetchPrice(coin);
        if (px == null) { notCoin++; continue; }
        final risk0 = (e0 - sl).abs();
        // broken plan from the bot (seen: AKE 4h with the stop 79% away and the target below zero)
        if (tp <= 0 || sl <= 0 || risk0 / e0 > 0.20) { bad++; continue; }
        // still between stop and target, and not more than 0.3R past the bot's entry (no chasing)
        if ((px - sl) * side <= 0 || (tp - px) * side <= 0 || risk0 <= 0 || (px - e0) * side > 0.3 * risk0) { moved++; continue; }
        final stopDist = (px - sl).abs();
        final riskUsd = paperAmount > 0 ? paperAmount * stopDist / px : paperEquity * paperRisk;
        final id = trades.isEmpty ? 1 : trades.map((t) => t.id).reduce(math.max) + 1;
        final tf = paperHoldHours.containsKey('${s['tf']}') ? '${s['tf']}' : '1h';
        final t = AppTrade(
          id: id, coin: coin, tf: tf, source: 'BOT', verdict: '${s['strategy']}', side: side, buys: 0, sells: 0, neutrals: 0,
          mood: 0, entry: px, sl: sl, tp: tp, score: 0, riskCash: riskUsd, amount: paperAmount > 0 ? paperAmount : 0,
          adx: null, atrPct: null, opened: DateTime.now(), regime: 'Bot focus', inds: '${s['strategy']} ${s['side']}',
        );
        trades.add(t);
        opened++;
        notifyPaper(t.id, 'Bot focus trade opened: $coin ${s['side']} ($tf)',
            '${s['strategy']}. Entry ${fmtPrice(px)}  SL ${fmtPrice(sl)}  TP ${fmtPrice(tp)}. Record: ${rec!.text}');
      }
      await savePaper();   // also saves the handled-signal list
      final parts = <String>[
        if (notFocus > 0) '$notFocus not focus',
        if (stale > 0) '$stale older than 30 min',
        if (notCoin > 0) '$notCoin not a Binance coin',
        if (busy > 0) '$busy coin already open / max open',
        if (moved > 0) '$moved price already moved',
        if (bad > 0) '$bad broken stop/target (stop over 20% away or target below 0)',
      ];
      botStatus = 'Bot focus ${hhmm(DateTime.now())}: ${fresh.length} new signals, $opened opened.${parts.isEmpty ? '' : ' Skipped: ${parts.join(', ')}.'}';
    } catch (e) {
      botStatus = 'Bot focus could not run: $e';
    } finally {
      botFollowBusy = false;
      if (mounted) setState(() {});
    }
  }

  Map<String, Edge> get focusMap {
    final k = trades.where((t) => !t.isOpen).length;
    if (k != _focusKey) { _focusKey = k; _focusEdges = focusEdges(trades); }
    return _focusEdges;
  }

  /// Focus filter: null = allowed, otherwise the reason the trade is skipped.
  String? focusBlock(String coin, int side, String inds) {
    if (focusMode == 0) return null;
    final f = focusMap;
    final sd = side == 1 ? 'BUY' : 'SELL';
    final c = f['c|$coin|$sd'];
    if (c != null && c.losing) return 'Focus: $coin $sd lost in both halves (${c.n} trades, ${c.sumR.toStringAsFixed(1)} R)';
    var good = 0, bad = 0;
    for (final ind in inds.split('|')) {
      final e = f['i|$ind|$sd'];
      if (e == null) continue;
      final rel = indicatorRel(e, f['s|$sd']);
      if (rel > 0) good++;
      if (rel < 0) bad++;
    }
    if (bad > good) return 'Focus: $bad agreeing indicators did worse than average $sd trades in both halves';
    if (focusMode == 2 && !(c != null && c.proven)) return 'Focus (proven only): $coin $sd is not proven yet';
    return null;
  }

  AppTrade? openPaperTrade(String coin, String tf, Analysis a, String source, [Map<String, dynamic>? q]) {
    if (a.side == 0 || a.atr.isNaN || a.atr <= 0) return null;
    final plan = tradePlan(a);
    if (plan[2] < 0.75 * planRR) return null;
    if (a.atr / a.last * 100 > 8 || plan[0] <= 0 || plan[1] <= 0) return null;   // illiquid coins with absurd stops, or a target below zero
    if (trades.any((t) => t.isOpen && t.coin == coin && t.tf == tf)) return null;
    final stopDist = (a.last - plan[0]).abs();
    if (stopDist <= 0) return null;
    // manual amount: P&L = price move % x amount, so a stop-out loses amount x stop distance %. Empty = risk 1% of the paper account.
    final indsNow = (q?['inds'] as String?) ?? [for (final x in [...a.ma, ...a.osc]) if (!isInfoOnly(x) && x.sig == a.side) x.name].join('|');
    if (source != 'manual') {
      final why = focusBlock(coin, a.side, indsNow);
      if (why != null) {
        focusSkipped++;
        paperRejected++;
        gateRejects.insert(0, GateReject(DateTime.now(), coin, tf, a.side, why));
        if (gateRejects.length > 60) gateRejects.removeLast();
        return null;
      }
    }
    final riskUsd = paperAmount > 0 ? paperAmount * stopDist / a.last : paperEquity * paperRisk;
    final id = trades.isEmpty ? 1 : trades.map((t) => t.id).reduce(math.max) + 1;
    final t = AppTrade(
      id: id, coin: coin, tf: tf, source: source, verdict: a.verdict, side: a.side, buys: a.buys, sells: a.sells,
      neutrals: a.neutrals, mood: news.isEmpty ? 0 : newsScore(coin), entry: a.last, sl: plan[0], tp: plan[1],
      score: a.score, riskCash: riskUsd, amount: paperAmount > 0 ? paperAmount : 0, adx: cleanNum(a.adx),
      atrPct: a.last == 0 ? null : cleanNum(a.atr / a.last * 100), opened: DateTime.now(),
      rvol: q?['rvol'] as double?, ext: q?['ext'] as double?, quality: (q?['q'] as int?) ?? 0,
      htfAgree: (q?['htf'] as int?) ?? 0, btc: (q?['btc'] as int?) ?? 0,
      regime: '${q?['regime'] ?? ''}',
      inds: indsNow,
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
    final extMax = gateExtMax[side] ?? 1.2;
    if (ext > extMax) veto = 'price stretched ${ext.toStringAsFixed(1)} ATR from EMA20 (chasing; max ${extMax.toStringAsFixed(1)} ATR)';
    final rsi = rsiLast(c, 14);
    final rsiLim = gateRsiLimit[side] ?? (side == 1 ? 70.0 : 30.0);
    if (veto == null && !rsi.isNaN && ((side == 1 && rsi > rsiLim) || (side == -1 && rsi < rsiLim))) veto = 'RSI exhausted (${rsi.toStringAsFixed(0)})';
    // relative volume of the last closed candle vs the previous 20
    double? rvol;
    final vols = closed.map((x) => x.volume).toList();
    if (vols.length > 22 && vols.skip(vols.length - 21).fold<double>(0, (a, b) => a + b) > 0) {
      final avg = vols.sublist(vols.length - 21, vols.length - 1).fold<double>(0, (a, b) => a + b) / 20;
      rvol = avg > 0 ? vols.last / avg : null;
    }
    if (veto == null && rvol != null && rvol < 0.7) veto = 'dead volume (${rvol.toStringAsFixed(2)}x average)';
    if (veto == null && rvol != null && rvol > 3.0) veto = 'volume spike may be exhaustion (${rvol.toStringAsFixed(2)}x average)';
    // ---- stretch veto: the Lab's Z-score says price is already stretched against this trade (a SELL into an oversold bounce, a BUY into an overbought run)
    final zs = sigOf(ac, 'Z-score (20)');
    if (veto == null && zs == -side) veto = 'Z-score says price is ${side == 1 ? 'overbought' : 'oversold'}, a ${side == 1 ? 'BUY' : 'SELL'} here chases the move';
    // ---- market regime, entry quality, support/resistance and candle momentum
    var regime = const Regime('Unknown', true, '');
    if (closed.length >= 120) {
      final hh = closed.map((x) => x.high).toList(), ll = closed.map((x) => x.low).toList();
      final atrS = wilder(trSeries(hh, ll, c), 14);
      final med = medianOf(atrS.sublist(atrS.length - 100));
      final ratio = med > 0 ? atrS.last / med : double.nan;
      regime = detectRegime(side: side, adx: ac.adx, atrRatio: ratio, emaFast: ema20, emaSlow: emaSeries(c, 50).last, last: c.last, rsi: rsi);
      if (veto == null && !regime.tradable) veto = '${regime.label}: ${regime.note}';
    }
    if (veto == null && c.length > 6 && ac.atr > 0) {
      final run = (c.last - c[c.length - 6]) * side / ac.atr;
      if (run > gateLateMoveAtr) veto = 'late entry: price already moved ${run.toStringAsFixed(1)} ATR in 5 candles (max ${gateLateMoveAtr.toStringAsFixed(1)})';
    }
    if (veto == null && ac.atr > 0 && closed.isNotEmpty) {
      final body = (closed.last.close - closed.last.open) * side / ac.atr;     // negative = the last candle went against the signal
      if (body < -gateCandleBodyAtr) veto = 'last candle moved ${(-body).toStringAsFixed(1)} ATR against it';
    }
    if (veto == null && ac.atr > 0) {
      if (side == 1 && ac.res.isNotEmpty && ac.res.first > ac.last && (ac.res.first - ac.last) < gateSrMinAtr * ac.atr) {
        veto = 'resistance ${fmtPrice(ac.res.first)} is only ${((ac.res.first - ac.last) / ac.atr).toStringAsFixed(1)} ATR above';
      }
      if (side == -1 && ac.sup.isNotEmpty && ac.sup.first < ac.last && (ac.last - ac.sup.first) < gateSrMinAtr * ac.atr) {
        veto = 'support ${fmtPrice(ac.sup.first)} is only ${((ac.last - ac.sup.first) / ac.atr).toStringAsFixed(1)} ATR below';
      }
    }
    if (veto == null && ac.score.abs() < paperMinScore + (gateMinScoreAdd[side] ?? 0.0)) {
      veto = 'score ${ac.score.abs().toStringAsFixed(2)} is below the ${side == 1 ? 'BUY' : 'SELL'} minimum';
    }
    if (veto == null) {
      final minStretch = gateStretchVeto[side] ?? 0;
      if (minStretch > 0) {
        var stretched = 0;
        for (final sn in stretchInds) {
          if (sigOf(ac, sn) == -side) stretched++;   // +1 (oversold) is against a SELL, -1 (overbought) against a BUY
        }
        if (stretched >= minStretch) veto = '$stretched stretch indicators say price is already ${side == -1 ? 'oversold' : 'overbought'}';
      }
    }
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
    gateLast['$coin|$tf'] = '${hhmm(DateTime.now())}|${why ?? 'OK'}';
    return {'ok': why == null, 'why': why, 'q': q, 'htf': htf, 'rvol': rvol, 'ext': ext, 'btc': btc, 'regime': regime.label};
  }

  /// Runs every minute. For each chosen timeframe whose candle just closed, checks the top coins once and opens paper trades.
  Future<void> paperScanCycle() async {
    if (!autoPaper || paperScanBusy || !paperLoaded || paperSource == 1) return;   // 1 = bot focus signals only
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
      if (coins.isEmpty) {
        paperStatus = 'No coins to check: the Binance futures coin list did not load${futuresError == null ? '' : ' ($futuresError)'}. Retrying every minute.';
        paperCoinsAt = DateTime(2000);
        return;
      }
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
      if (jobs.isEmpty) {
        if (!paperStatus.startsWith('Last check')) {
          final tfs = mtfList.where(paperTfs.contains).toList();
          paperStatus = tfs.isEmpty ? 'No timeframe is selected for auto trading.' : 'Waiting for the next candle close on ${tfs.join(', ')}.';
        }
        return;
      }
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
            final trendOk = !(ac.side == 0 || ac.score.abs() < paperMinScore) && !(paperMinAdx > 0 && !ac.adx.isNaN && ac.adx < paperMinAdx);   // no trend, no edge in the Lab
            final mr = paperMr ? mrSignal(ac) : null;
            if (!trendOk && mr == null) return null;
            return {'coin': j[0], 'tf': j[1], 'cs': cs, 'ac': ac, 'trend': trendOk, 'mr': mr};
          } catch (_) {
            return null;
          }
        }));
        cands.addAll(res.whereType<Map<String, dynamic>>());
        await Future.delayed(const Duration(milliseconds: 250));      // stay well inside the exchange rate limit
      }
      cands.sort((a, b) => (b['ac'] as Analysis).score.abs().compareTo((a['ac'] as Analysis).score.abs()));
      var opened = 0, rejected = 0, qchecked = 0, sOpen = 0, sCool = 0, sNews = 0, sMax = 0, sPlan = 0;
      final focus0 = focusSkipped;
      final weak = jobs.length - cands.length;
      paperSignals += cands.length;
      for (final m in cands) {
        if (trades.where((t) => t.isOpen && (t.source == 'auto' || t.source == 'MR' || t.source == 'BOT')).length >= paperMaxOpen) { sMax = cands.length; break; }   // manual trades do not use up the auto limit
        final coin = m['coin'] as String, tf = m['tf'] as String;
        final ac = m['ac'] as Analysis;
        final cs = m['cs'] as List<Candle>;
        final isTrend = m['trend'] == true;
        final mrSig = m['mr'] as MrSignal?;
        if (trades.any((t) => t.isOpen && t.coin == coin && t.source != 'NEWS')) { sOpen++; continue; } // avoid duplicate exposure across timeframes
        if (eventSoon(coin) != null) { sNews++; continue; }                         // same news blackout as the Final call
        final holdH = paperHoldHours[tf] ?? 48;
        final cooldown = trades.any((t) => !t.isOpen && t.coin == coin && t.tf == tf && t.closed != null &&
            DateTime.now().difference(t.closed!).inMinutes < holdH * 15);   // wait a quarter of the hold time after a close
        if (cooldown) { sCool++; continue; }
        if (!isTrend) {
          // mean-reversion BUY: same news blackout, cooldown, one-trade-per-coin and 1:1 plan as the trend trades, its own label
          if (mrSig == null) continue;
          final mrAnalysis = Analysis(ac.ma, ac.osc, ac.info, ac.buys, ac.sells, ac.neutrals, cs.last.open, ac.atr, ac.adx, mrSig.side * 0.5, ac.sup, ac.res);
          final nm = openPaperTrade(coin, tf, mrAnalysis, 'MR', {'inds': mrSig.inds, 'regime': 'Mean reversion'});
          if (nm == null) sPlan++;
          if (nm != null) {
            opened++;
            notifyPaper(nm.id, 'Mean-reversion trade opened: ${nm.coin} ${nm.side > 0 ? 'BUY' : 'SELL'} ($tf)',
                'Entry ${fmtPrice(nm.entry)}  SL ${fmtPrice(nm.sl)}  TP ${fmtPrice(nm.tp)}');
          }
          continue;
        }
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
            gateRejects.insert(0, GateReject(DateTime.now(), coin, tf, ac.side, '${q['why']}'));
            if (gateRejects.length > 60) gateRejects.removeLast();
            continue;
          }
        }
        final nt = openPaperTrade(coin, tf, entryAnalysis, 'auto', q);
        if (nt == null) sPlan++;
        if (nt != null) {
          opened++;
          notifyPaper(nt.id, 'Paper trade opened: ${nt.coin} ${nt.side > 0 ? 'BUY' : 'SELL'} ($tf)',
              'Entry ${fmtPrice(nt.entry)}  SL ${fmtPrice(nt.sl)}  TP ${fmtPrice(nt.tp)}');
        }
      }
      if (opened > 0) await savePaper();
      final sFocus = focusSkipped - focus0;
      final parts = <String>[
        if (weak > 0) '$weak no signal / weak score or ADX',
        if (rejected > 0) '$rejected failed the quality gate',
        if (sOpen > 0) '$sOpen coin already has an open trade',
        if (sCool > 0) '$sCool cooldown after a close',
        if (sNews > 0) '$sNews news blackout',
        if (sFocus > 0) '$sFocus Focus filter',
        if (sPlan - sFocus > 0) '${sPlan - sFocus} stop/target not valid',
        if (sMax > 0) 'max open trades ($paperMaxOpen) reached',
      ];
      paperStatus = 'Last check ${hhmm(DateTime.now())}: ${jobs.length} pairs checked, $opened opened.'
          '${parts.isEmpty ? '' : ' Skipped: ${parts.join(', ')}.'}';
    } catch (e) {
      paperStatus = 'Auto paper trading could not run: $e';
    } finally {
      paperScanBusy = false;
      if (mounted) setState(() {});
    }
  }

  /// Current market rate for every open paper trade. Binance coins: one best bid/ask request for all symbols (futures, then spot).
  /// Forex, gold and oil have no free bid/ask, so they use Yahoo Finance's latest price (can be delayed) and are labelled so.
  /// Polling every 3 seconds, not a WebSocket stream; a quote older than 12 s shows STALE and older than 60 s OFFLINE.
  Future<void> refreshLive({bool force = false}) async {
    if (liveBusy) return;
    final open = trades.where((t) => t.isOpen).toList();
    if (open.isEmpty) return;
    liveBusy = true;
    try {
      final crypto = <String>{}, other = <String>{};
      for (final t in open) {
        (yahooPairs.containsKey(t.coin) ? other : crypto).add(t.coin);
      }
      if (crypto.isNotEmpty) {
        if (futSymbols.isEmpty) await loadFutures();
        final fut = await fetchBookTickers();
        Map<String, List<double>> spot = {};
        final now = DateTime.now();
        for (final c in crypto) {
          final pair = futSymbols[c] ?? '${c}USDT';
          var b = fut[pair];
          var src = 'Binance Futures';
          if (b == null) {
            if (spot.isEmpty) spot = await fetchBookTickers(spot: true);
            b = spot[pair];
            src = 'Binance Spot';
          }
          if (b != null) liveQuotes[c] = LiveQuote(b[0], b[1], (b[0] + b[1]) / 2, now, src);
        }
      }
      for (final c in other) {
        final q = liveQuotes[c];
        if (!force && q != null && q.ageSec < 10) continue;
        final px = await fetchPrice(c);
        if (px != null) liveQuotes[c] = LiveQuote(px, px, px, DateTime.now(), 'Yahoo Finance (may be delayed)');
      }
      // price path: unrealized R about every 5 minutes, so exits (break-even, trailing stop) can be tested on real paths later
      final nowP = DateTime.now();
      var pathChanged = false;
      for (final t in open) {
        final qq = liveQuotes[t.coin];
        final pp = livePnl(t, qq);
        if (pp == null || qq == null || qq.ageSec > 30) continue;
        if (t.pathAt != null && nowP.difference(t.pathAt!).inMinutes < 5) continue;
        if (t.path.length < 4000) t.path = (t.path.isEmpty ? '' : '${t.path};') + pp.r.toStringAsFixed(2);
        t.pathAt = nowP;
        pathChanged = true;
      }
      if (pathChanged && nowP.difference(lastPathSave).inMinutes >= 10) {
        lastPathSave = nowP;
        await savePaper();
      }
      liveAt = DateTime.now();
    } catch (_) {
    } finally {
      liveBusy = false;
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
        final last = paperCheckedAt[t.coin];
        if (last != null && DateTime.now().difference(last).inSeconds < (open.length > 60 ? 60 : 10)) continue;   // per-coin pause keeps us inside the exchange rate limit and the app fast
        byCoin.putIfAbsent(t.coin, () => []).add(t);
      }
      if (byCoin.isEmpty) { paperBusy = false; return; }
      for (final c in byCoin.keys) { paperCheckedAt[c] = DateTime.now(); }
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
              if (settleTrade(t, cs)) {
                closedNow++;
                notifyPaper(t.id, 'Paper trade closed: ${t.coin} ${t.reason}',
                    '${t.side > 0 ? 'BUY' : 'SELL'} ${t.tf}  ${t.r >= 0 ? '+' : ''}${t.r.toStringAsFixed(2)}R');
              }
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
    setBackgroundService(v);
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

  Future<void> downloadProfitLog() async {
    if (!trades.any((t) => !t.isOpen)) return toast('No closed in-app trades yet.');
    await downloadCsv('app_profit_analysis.csv', profitAnalysisCsv(trades));
  }

  /// Shares the trade log, the profit breakdown and the per-indicator rows together in one share sheet.
  Future<void> shareDetailLogs() async {
    if (!trades.any((t) => !t.isOpen)) return toast('No closed in-app trades yet.');
    final files = <XFile>[];
    for (final e in {
      'app_paper_trades.csv': tradesToCsv(trades),
      'app_profit_analysis.csv': profitAnalysisCsv(trades),
      'app_trade_indicators.csv': tradeIndicatorsCsv(trades),
    }.entries) {
      final f = await _writeTemp(e.key, e.value);
      if (f != null) files.add(XFile(f.path, mimeType: 'text/csv'));
    }
    if (files.isEmpty) return;
    try {
      await Share.shareXFiles(files, subject: 'Detail logs (trades, profit analysis, indicators)');
    } catch (e) {
      toast('Could not share the files: $e');
    }
  }

  Future<void> downloadAllLogs() => downloadAllLogsZip();

  Future<void> downloadAllLogsSeparate() async {
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

  /// Marks of the selected open paper trade for the Markets chart (only while that coin is shown).
  List<ChartMark> focusMarks() {
    if (chartExtra.isNotEmpty && chartExtraCoin == marketSymbol) return chartExtra;
    final t = chartTrade ?? focusTrade;
    if (t == null || t.coin != marketSymbol) return const [];
    return [
      ChartMark('Entry', t.entry, Colors.blue), ChartMark('SL', t.sl, Colors.red), ChartMark('TP', t.tp, Colors.green),
      if (!t.isOpen && t.exitPx > 0) ChartMark('Exit', t.exitPx, Colors.orange),
    ];
  }

  /// Tapping a trade in the Paper tab opens its coin and timeframe in Markets and draws its entry, stop and target.
  void openTrade(AppTrade t, BuildContext ctx) {
    focusTrade = t.isOpen ? t : null;
    chartExtra = [];
    chartTrade = t;
    chartJump = t.opened;
    openCoin(t.coin, t.tf, ctx);
  }

  Widget focusBanner() {
    final t = focusTrade;
    if (t == null || !t.isOpen || t.coin != marketSymbol) return const SizedBox.shrink();
    final p = livePnl(t, liveQuotes[t.coin]);
    final col = p == null ? null : (p.usd >= 0 ? Colors.green : Colors.red);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Paper trade #${t.id}: ${t.side == 1 ? 'BUY' : 'SELL'} ${t.coin} (${t.tf}), \$${t.notional.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.w700)),
          Text('Entry ${fmtPrice(t.entry)}   SL ${fmtPrice(t.sl)}   TP ${fmtPrice(t.tp)}   open ${sinceText(t.opened)}', style: const TextStyle(fontSize: 12)),
          if (p != null)
            Text('Now ${fmtPrice(p.px)}   P&L ${p.usd >= 0 ? '+' : ''}${p.usd.toStringAsFixed(2)} \$ (${p.r >= 0 ? '+' : ''}${p.r.toStringAsFixed(2)}R)',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: col)),
          Row(children: [
            TextButton.icon(onPressed: () => closeTradeManually(t), icon: const Icon(Icons.stop_circle_outlined, size: 18), label: const Text('Close trade now')),
            TextButton(onPressed: () => setState(() => focusTrade = null), child: const Text('Hide lines')),
          ]),
        ]),
      ),
    );
  }

  /// Closes an open paper trade at the current market rate (bid for a BUY, ask for a SELL), with the same 0.05R fee as other exits.
  Future<void> closeTradeManually(AppTrade t) async {
    if (!t.isOpen) return;
    var q = liveQuotes[t.coin];
    if (q == null || q.ageSec > 60) {
      await refreshLive(force: true);
      q = liveQuotes[t.coin];
    }
    double? px = q != null && q.ageSec <= 60 ? q.exitPrice(t.side) : null;
    px ??= await fetchPrice(t.coin);
    if (px == null) return toast('No market price for ${t.coin} right now. Try again in a moment.');
    final r = (px - t.entry) * t.side / t.riskPx - paperCostR;
    final usd = r * t.riskCash;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('Close ${t.coin} ${t.side == 1 ? 'BUY' : 'SELL'} (${t.tf})?'),
        content: Text('Exit at ${fmtPrice(px!)} (${t.side == 1 ? 'bid' : 'ask'}).\nResult: ${usd >= 0 ? '+' : ''}${usd.toStringAsFixed(2)} \$ (${r >= 0 ? '+' : ''}${r.toStringAsFixed(2)}R), fee included.\nEntry was ${fmtPrice(t.entry)}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Keep open')),
          TextButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('Close trade')),
        ],
      ),
    );
    if (ok != true || !t.isOpen) return;     // cancelled, or the stop/target was hit while the dialog was open
    t.exitPx = px;
    t.reason = 'MANUAL';
    t.ambiguous = false;
    t.closed = DateTime.now();
    t.status = 'closed';
    t.r = r;
    if (focusTrade?.id == t.id) focusTrade = null;
    await savePaper();
    if (mounted) setState(() {});
    toast('${t.coin} closed by you: ${usd >= 0 ? '+' : ''}${usd.toStringAsFixed(2)} \$ (${r >= 0 ? '+' : ''}${r.toStringAsFixed(2)}R).');
  }

  /// Tapping a bot signal or a Lab trade: show that coin's chart at that time with its entry, stop and target.
  void openLevels(String coin, String tf, DateTime at, double entry, double sl, double tp, BuildContext ctx) {
    chartTrade = null;
    focusTrade = null;
    chartExtraCoin = coin;
    chartExtra = [ChartMark('Entry', entry, Colors.blue), ChartMark('SL', sl, Colors.red), ChartMark('TP', tp, Colors.green)];
    chartJump = at;
    openCoin(coin, tfList.contains(tf) ? tf : marketInterval, ctx);
  }

  void openSignal(Map<String, dynamic> s, BuildContext ctx) {
    final coin = botCoin('${s['symbol']}');
    final e = (s['entry'] as num?)?.toDouble(), sl = (s['sl'] as num?)?.toDouble(), tp = (s['tp'] as num?)?.toDouble();
    if (coin == null || e == null || sl == null || tp == null) {
      toast('No chart for ${s['symbol']} (not a Binance coin).');
      return;
    }
    openLevels(coin, '${s['tf']}', DateTime.tryParse('${s['time']}')?.toLocal() ?? DateTime.now(), e, sl, tp, ctx);
  }

  void openCoin(String coin, String tf, BuildContext ctx) {
    setState(() { marketSymbol = coin; marketInterval = tf; mtf = {}; });
    loadMarket().then((_) => showChartTime());
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
      setState(() { marketSymbol = choice; mtf = {}; chartTrade = null; chartExtra = []; });
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
      newsTradeCycle();
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
      final r = await ghGet(feedUrl, timeout: const Duration(seconds: 20));
      if (r.statusCode != 200) {
        throw 'Feed not found (HTTP ${r.statusCode}). Run the bot once and make sure the repo is public.';
      }
      data = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      error = null;
    } catch (e) {
      error = netMsg(e);
    }
    if (mounted) setState(() => loading = false);
  }

  /// Live candles plus the older ones loaded while scrolling back.
  List<Candle> chartCandles() {
    final key = '$marketSymbol|$marketInterval';
    final live = candles[key] ?? <Candle>[];
    final old = chartOlder[key] ?? const <Candle>[];
    if (live.isEmpty || old.isEmpty) return live;
    return [...old.where((c) => c.time.isBefore(live.first.time)), ...live];
  }

  Future<void> loadOlderChart() async {
    final key = '$marketSymbol|$marketInterval';
    if (chartBusy || chartNoMore.contains(key)) return;
    final all = chartCandles();
    if (all.isEmpty) return;
    chartBusy = true;
    if (mounted) setState(() {});
    try {
      final more = await fetchOlderCandles(marketSymbol, marketInterval, all.first.time);
      if (more.isEmpty) {
        chartNoMore.add(key);
      } else {
        chartOlder[key] = [...more, ...(chartOlder[key] ?? const <Candle>[])];
        if ((chartOlder[key]?.length ?? 0) > 6000) chartNoMore.add(key);       // enough history for a phone
      }
    } catch (_) {
    } finally {
      chartBusy = false;
      if (mounted) setState(() {});
    }
  }

  /// After a trade was tapped: load history back to its entry and scroll the chart there.
  Future<void> showChartTime() async {
    final t = chartJump;
    if (t == null) return;
    chartJump = null;
    final key = '$marketSymbol|$marketInterval';
    for (var i = 0; i < 8; i++) {
      final all = chartCandles();
      if (all.isEmpty || !all.first.time.isAfter(t) || chartNoMore.contains(key)) break;
      await loadOlderChart();
    }
    final all = chartCandles();
    if (all.isEmpty) return;
    final after = all.where((c) => c.time.isAfter(t)).length;                    // candles since the entry
    chartKey = key;
    chartOffset = math.max(0, after - chartCount * 0.7).toDouble();             // entry at about one third from the left
    if (mounted) setState(() {});
  }

  Widget marketTab() {
    final key = '$marketSymbol|$marketInterval';
    if (key != chartKey) { chartKey = key; chartOffset = 0; }                    // new coin or timeframe: back to the newest candle
    final all = chartCandles();
    final count = math.min(chartCount, math.max(all.length, 1));
    final maxOff = math.max(0, all.length - count).toDouble();
    if (chartOffset > maxOff) chartOffset = maxOff;
    final end = all.length - chartOffset.round();
    final list = all.isEmpty ? <Candle>[] : all.sublist(math.max(0, end - count), end);
    final price = latestPrices[marketSymbol];
    String when(DateTime t) => '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}/${t.year % 100} ${hhmm(t)}';
    void select(String coin) { setState(() { marketSymbol = coin; mtf = {}; chartTrade = null; chartExtra = []; }); loadMarket(); }
    return RefreshIndicator(onRefresh: loadMarket, child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(12), children: [
      Wrap(spacing: 8, runSpacing: 4, children: [
        ActionChip(avatar: const Icon(Icons.search, size: 18), label: Text(futSymbols.isEmpty ? 'All futures coins' : 'All coins (${futSymbols.length})'), onPressed: pickCoin),
        for (final a in {...favorites, marketSymbol}) ChoiceChip(label: Text(a), selected: marketSymbol == a, onSelected: (_) => select(a)),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [for (final tf in tfList) ChoiceChip(label: Text(tf), selected: marketInterval == tf, onSelected: (_) { setState(() => marketInterval = tf); loadMarket(); })]),
      const SizedBox(height: 8),
      focusBanner(),
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('$marketSymbol  $marketInterval', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          Text(price == null ? '-' : '${fxPairs.contains(marketSymbol) ? '' : '\$'}${price.toStringAsFixed(decimalsFor(marketSymbol, price))}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        ]),
        if (marketLoading || chartBusy) const LinearProgressIndicator(),
        if (marketError != null) Text(marketError!, style: const TextStyle(color: Colors.orange)),
        const SizedBox(height: 6),
        if (list.length > 1)
          LayoutBuilder(builder: (ctx, box) {
            final step = box.maxWidth / list.length;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) {
                setState(() => chartOffset = (chartOffset + d.delta.dx / step).clamp(0.0, maxOff).toDouble());   // drag right = older candles
                if (maxOff - chartOffset < 20) loadOlderChart();
              },
              child: SizedBox(
                height: 420,
                child: CustomPaint(
                  painter: CandlePainter(list, Theme.of(context).brightness == Brightness.dark, const <double>[], const <double>[], focusMarks()),
                  child: const SizedBox.expand(),
                ),
              ),
            );
          })
        else
          const SizedBox(height: 300, child: Center(child: Text('Waiting for candlestick data...'))),
        if (list.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('${when(list.first.time)}  to  ${when(list.last.time)}${chartOffset > 0 ? '   (past view)' : '   (live)'}', style: const TextStyle(fontSize: 12)),
          ),
        Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          IconButton(tooltip: 'Older', icon: const Icon(Icons.chevron_left), onPressed: () { setState(() => chartOffset = math.min(maxOff, chartOffset + count / 2)); if (maxOff - chartOffset < 20) loadOlderChart(); }),
          IconButton(tooltip: 'Newer', icon: const Icon(Icons.chevron_right), onPressed: chartOffset <= 0 ? null : () => setState(() => chartOffset = math.max(0.0, chartOffset - count / 2))),
          IconButton(tooltip: 'Fewer candles (zoom in)', icon: const Icon(Icons.zoom_in), onPressed: chartCount <= 30 ? null : () => setState(() => chartCount = math.max(30, chartCount * 2 ~/ 3))),
          IconButton(tooltip: 'More candles (zoom out)', icon: const Icon(Icons.zoom_out), onPressed: chartCount >= 400 ? null : () => setState(() => chartCount = math.min(400, chartCount * 3 ~/ 2))),
          TextButton(onPressed: chartOffset <= 0 ? null : () => setState(() => chartOffset = 0), child: const Text('Latest')),
        ]),
        Text('Drag the chart left or right to move through past candles. ${all.length} candles loaded'
            '${chartNoMore.contains(key) ? ' (all available history).' : '; more load automatically as you go back.'}', style: const TextStyle(fontSize: 11)),
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
    String tag(Reading r) => isInfoOnly(r) ? 'info only' : lab(r.sig);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 10, bottom: 2), child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
      for (final r in rows)
        _indicatorRow(r.name, title == 'Levels' ? r.value : '${r.value}  ${tag(r)}', isInfoOnly(r) ? null : col(r.sig)),
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
      gateNote(),
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
              if (t == null) return toast('Not opened: needs a clear signal, a valid 1:1 plan and no open trade on this coin.');
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
      const Padding(padding: EdgeInsets.only(top: 8), child: Text('Calculated from the last 300 candles. Support and resistance are swing levels read from the chart (green and red dashed lines). Stop and target use those levels when they are close, otherwise 1.5x ATR and 1x risk (1:1). Not a guaranteed signal. Gold, forex and oil are closed on weekends. Forex has no real volume, so volume indicators (VWAP, MFI, OBV) only appear for crypto, gold and oil.', style: TextStyle(fontSize: 11))),
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

  /// Opens paper trades from fresh headlines (60 minutes or newer) with a keyword score, on every timeframe.
  Future<void> newsTradeCycle() async {
    if (!newsAuto || !paperLoaded || newsTradeBusy || news.isEmpty) return;
    final now = DateTime.now();
    String key(NewsItem n) => '${n.source}|${n.title}';
    final fresh = news.where((n) => n.time != null && n.score != 0 && now.difference(n.time!).inMinutes <= 60 && !newsSeen.contains(key(n))).toList();
    if (fresh.isEmpty) return;
    newsTradeBusy = true;
    var opened = 0, heads = 0, noCoin = 0, busy = 0, failed = 0;
    try {
      for (final n in fresh.reversed) {                // oldest first
        newsSeen.add(key(n));
        final t = ' ${n.title.toLowerCase()} ';
        final coins = [for (final e in newsCoinKeys.entries) if (futSymbols.containsKey(e.key) && e.value.any(t.contains)) e.key];
        if (coins.isEmpty) { noCoin++; continue; }
        final side = n.score > 0 ? 1 : -1;
        var made = 0;
        for (final coin in coins.take(3)) {
          final px = await fetchPrice(coin);
          if (px == null) { failed++; continue; }
          for (final tf in mtfList) {
            if (trades.any((x) => x.isOpen && x.source == 'NEWS' && x.coin == coin && x.tf == tf)) { busy++; continue; }
            try {
              final cs = await fetchCandles(coin, tf);
              final a = cs.length < 20 ? double.nan : atrWilder(cs.sublist(0, cs.length - 1));
              if (a.isNaN || a <= 0) { failed++; continue; }
              final stop = newsStopAtr * a;
              final riskUsd = paperAmount > 0 ? paperAmount * stop / px : paperEquity * paperRisk;
              final id = trades.isEmpty ? 1 : trades.map((x) => x.id).reduce(math.max) + 1;
              trades.add(AppTrade(
                id: id, coin: coin, tf: tf, source: 'NEWS', verdict: n.title.length > 90 ? '${n.title.substring(0, 90)}...' : n.title,
                side: side, buys: 0, sells: 0, neutrals: 0, mood: n.score, entry: px, sl: px - side * stop, tp: px + side * planRR * stop,
                score: n.score.toDouble(), riskCash: riskUsd, amount: paperAmount > 0 ? paperAmount : 0, adx: null, atrPct: a / px * 100,
                opened: DateTime.now(), regime: 'News', inds: n.source,
              ));
              opened++;
              made++;
            } catch (_) {
              failed++;
            }
          }
        }
        if (made > 0) {
          heads++;
          notifyPaper(trades.last.id, 'News trades opened: ${coins.take(3).join(', ')} ${side == 1 ? 'BUY' : 'SELL'} ($made timeframes)', n.title);
        }
      }
      await savePaper();
      final parts = <String>[
        if (noCoin > 0) '$noCoin headlines name no tradable coin',
        if (busy > 0) '$busy coin/timeframe already has a news trade',
        if (failed > 0) '$failed price or candle errors',
      ];
      newsTradeStatus = 'News trades ${hhmm(DateTime.now())}: ${fresh.length} new headlines, $opened trades from $heads of them.'
          '${parts.isEmpty ? '' : ' Skipped: ${parts.join(', ')}.'}';
    } catch (e) {
      newsTradeStatus = 'News trading could not run: $e';
    } finally {
      newsTradeBusy = false;
      if (mounted) setState(() {});
    }
  }

  Widget newsTradesCard() {
    final nt = trades.where((t) => t.source == 'NEWS').toList();
    final closed = nt.where((t) => !t.isOpen).toList();
    final st = PStats(closed);
    String line(String label, Iterable<AppTrade> l) {
      final p = PStats(l);
      final open = l.where((t) => t.isOpen).length;
      return '$label: ${p.n} closed${p.n == 0 ? '' : ', ${p.winPct.toStringAsFixed(0)}% wins, ${p.sumR >= 0 ? '+' : ''}${p.sumR.toStringAsFixed(1)}R'}${open > 0 ? ', $open open' : ''}';
    }
    final recent = nt.reversed.take(20).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Auto paper trades from news', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
            Switch(value: newsAuto, onChanged: (v) { setState(() => newsAuto = v); savePaper(); if (v) newsTradeCycle(); }),
          ]),
          Text('A new headline (60 min or newer) with a bullish or bearish keyword score that names a coin opens a paper trade on that coin on '
              'all 6 timeframes (${mtfList.join(', ')}): BUY for bullish, SELL for bearish. Stop ${newsStopAtr.toStringAsFixed(1)} ATR of that timeframe, '
              'target 1:${fmtRR(planRR)} (your setting), normal time limit per timeframe. One news trade per coin and timeframe at a time. '
              'Runs while the app is open or minimized. Separate from the other auto trades.', style: const TextStyle(fontSize: 11)),
          if (newsTradeStatus.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(newsTradeStatus, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
          const SizedBox(height: 6),
          Text(nt.isEmpty ? 'No news trades yet.' : line('All news trades', nt),
              style: TextStyle(fontWeight: FontWeight.w600, color: st.n == 0 ? null : st.sumR >= 0 ? Colors.green : Colors.red)),
          if (nt.isNotEmpty) ...[
            for (final sd in const [1, -1]) Text(line(sd == 1 ? 'BUY (bullish)' : 'SELL (bearish)', nt.where((t) => t.side == sd)), style: const TextStyle(fontSize: 12)),
            for (final tf in mtfList) Text(line(tf, nt.where((t) => t.tf == tf)), style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            const Text('Latest news trades (tap to see on the chart)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            for (final t in recent)
              InkWell(
                onTap: () => openTrade(t, context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Text('${t.side == 1 ? 'BUY' : 'SELL'} ${t.coin} ${t.tf}  ${ago(t.opened.toIso8601String())}\n${t.verdict}',
                        maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
                    Text(t.isOpen ? 'OPEN' : '${t.reason}\n${t.r >= 0 ? '+' : ''}${t.r.toStringAsFixed(2)}R', textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.isOpen ? Colors.grey : t.r >= 0 ? Colors.green : Colors.red)),
                  ]),
                ),
              ),
          ],
        ]),
      ),
    );
  }

  /// The only download in the app: every log in one ZIP file.
  Widget zipButton() => ElevatedButton.icon(
        onPressed: allLogsBusy ? null : downloadAllLogsZip,
        icon: const Icon(Icons.download_for_offline),
        label: Text(allLogsBusy ? 'Collecting logs...' : 'Download all logs (one ZIP)'),
      );

  /// Every log in one ZIP file: app trades, profit analysis, bot log, bot focus account, Lab, news and Experiment lab.
  Future<void> downloadAllLogsZip() async {
    if (allLogsBusy) return;
    allLogsBusy = true;
    if (mounted) setState(() {});
    toast('Collecting all logs...');
    try {
      final files = <String, String>{};
      final notes = <String>[];
      if (trades.isNotEmpty) {
        files['app_paper_trades.csv'] = tradesToCsv(trades);
        files['app_trade_indicators.csv'] = tradeIndicatorsCsv(trades);
        if (trades.any((t) => !t.isOpen)) files['app_profit_analysis.csv'] = profitAnalysisCsv(trades);
        final nt = trades.where((t) => t.source == 'NEWS').toList();
        if (nt.isNotEmpty) files['news_trades.csv'] = tradesToCsv(nt);
      }
      if (news.isNotEmpty) {
        files['news_headlines.csv'] = [
          'time_utc,source,score,title',
          for (final n in news) [n.time?.toUtc().toIso8601String() ?? '', csvCell(n.source), n.score, csvCell(n.title)].join(','),
        ].join('\n') + '\n';
      }
      final bot = await fetchPaperCsv();
      if (bot != null) { files['bot_paper_log.csv'] = bot; } else { notes.add('bot_paper_log.csv: could not download the bot log.'); }
      if (botFocusAll.isNotEmpty) {
        files['bot_focus_account.csv'] = [
          'opened_utc,closed_utc,symbol,side,strategy,tf,status,r_multiple',
          for (final t in botFocusAll)
            [t.opened.toUtc().toIso8601String(), t.closed?.toUtc().toIso8601String() ?? '', t.sym, t.side, csvCell(t.strat), t.tf, t.status, t.r ?? ''].join(','),
        ].join('\n') + '\n';
      }
      if (labAgg.isNotEmpty || labRows.isNotEmpty || labPending.isNotEmpty) {
        files['lab_indicator_accuracy.csv'] = labAggCsv(labAgg);
        files['lab_signal_snapshots.csv'] = labRowsCsv(labRows);
        files['lab_trades.csv'] = labTradesCsvAll();
      }
      // Experiment lab files from the exp-data branch on GitHub
      final eu = expUrl();
      if (eu != null) {
        await loadExp();
        final d = expData;
        if (d != null) {
          files['experiments_summary.csv'] = expSummaryCsv(d);
          files['experiments_last_run.json'] = const JsonEncoder.withIndent('  ').convert(
              {'updated': d['updated'], 'coins': d['coins'], 'tfs': d['tfs'], 'open': d['open'], 'closed': d['closed'], 'run': d['run']});
        } else {
          notes.add('experiments_summary.csv: ${expError ?? 'not available'}');
        }
        for (final f in const ['exp_stats.json', 'exp_state.json']) {
          try {
            final r = await ghGet(eu.replaceAll('exp_summary.json', f), timeout: const Duration(seconds: 60));
            if (r.statusCode != 200) { notes.add('$f: HTTP ${r.statusCode}'); continue; }
            final j = jsonDecode(utf8.decode(r.bodyBytes));
            if (f == 'exp_stats.json') files['experiments_daily.csv'] = expDailyCsv(j as Map<String, dynamic>);
            if (f == 'exp_state.json') files['experiments_open_trades.csv'] = expOpenCsv(j as Map<String, dynamic>);
          } catch (e) {
            notes.add('$f: $e');
          }
        }
      }
      if (files.isEmpty) {
        toast('No logs are available to download yet.');
        return;
      }
      files['README.txt'] = [
        'Signal Bot logs, ${DateTime.now().toUtc().toIso8601String()} UTC',
        '',
        for (final k in files.keys) k,
        if (notes.isNotEmpty) ...['', 'Not included:', ...notes],
      ].join('\n') + '\n';
      final bytes = zipFiles(files);
      final ts = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final name = 'signal_bot_logs_${ts.year}${two(ts.month)}${two(ts.day)}_${two(ts.hour)}${two(ts.minute)}.zip';
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Save all logs',
        fileName: name,
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        bytes: bytes,
      );
      toast(saved == null ? 'Download cancelled.' : 'Saved ${files.length - 1} logs in $name.');
    } catch (e) {
      toast('Could not save the logs: $e');
    } finally {
      allLogsBusy = false;
      if (mounted) setState(() {});
    }
  }

  String labTradesCsvAll() {
    final lines = ['indicator,time_utc,coin,tf,style,side,entry,target,stop,atr,result,r_multiple,move_atr_at_horizon'];
    void add(LabSnap x, bool open) {
      x.votes.forEach((n, sd) {
        final tr = LabTrade(x, sd, open);
        lines.add([csvCell(n), x.t0.toUtc().toIso8601String(), x.coin, x.tf, styleOf(x.tf), sd == 1 ? 'BUY' : 'SELL', x.price, tr.tp, tr.sl, x.atr,
          tr.result, open ? '' : tr.r.toStringAsFixed(3), open ? '' : x.move.toStringAsFixed(3)].join(','));
      });
    }
    for (final x in labRows) { add(x, false); }
    for (final x in labPending) { add(x, true); }
    return lines.join('\n') + '\n';
  }

  String expSummaryCsv(Map<String, dynamic> d) {
    final lines = ['view,name,timeframe,side,coin,n,win_pct_1to1,R_1to1,pf_1to1,R_1to1_older_half,R_1to1_newer_half,'
        'win_pct_1to2,R_1to2,pf_1to2,R_1to2_older_half,R_1to2_newer_half'];
    final rows = (d['rows'] as Map? ?? {}).cast<String, dynamic>();
    const views = {'all': 'All', 'I': 'Indicator', 'i': 'Indicator + timeframe', 'c': 'Coin', 't': 'Timeframe', 'ic': 'Indicator + coin',
      'L': 'App Lab rules', 'l': 'App Lab rules + timeframe'};
    for (final e in rows.entries) {
      final p = e.key.split('|');
      final v = p[0];
      String name = '', tf = '', side = '', coin = '';
      if (v == 'I' || v == 'L') { name = p[1]; side = p[2]; }
      if (v == 'i' || v == 'l') { name = p[1]; tf = p[2]; side = p[3]; }
      if (v == 'c') { coin = p[1]; side = p[2]; }
      if (v == 't') { tf = p[1]; side = p[2]; }
      if (v == 'ic') { name = p[1]; side = p[2]; coin = p[3]; }
      lines.add([views[v] ?? v, csvCell(name), tf, side, coin, ...(e.value as List)].join(','));
    }
    return lines.join('\n') + '\n';
  }

  String expDailyCsv(Map<String, dynamic> j) {
    final lines = ['day,key,n,wins_1to1,R_1to1,loss_R_1to1,wins_1to2,R_1to2,loss_R_1to2'];
    for (final d in j.entries) {
      for (final e in (d.value as Map).entries) {
        lines.add([d.key, csvCell('${e.key}'), ...(e.value as List)].join(','));
      }
    }
    return lines.join('\n') + '\n';
  }

  String expOpenCsv(Map<String, dynamic> j) {
    final lines = ['indicator,coin,tf,side,entry,stop_distance,entry_day,bars_held,result_1to1_so_far,result_1to2_so_far'];
    for (final t in (j['open'] as List? ?? const [])) {
      final m = t as Map;
      lines.add([csvCell('${m['k']}'), m['c'], m['tf'], m['s'] == 1 ? 'BUY' : 'SELL', m['e'], m['r'], m['d'], m['b'], m['o1'] ?? '', m['o2'] ?? ''].join(','));
    }
    return lines.join('\n') + '\n';
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
        newsTradesCard(),
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
        .where((s) => (filter == 'All' || s['side'] == filter) && (tfFilter == 'All' || s['tf'] == tfFilter) &&
            (!sigFocusOnly || botRec.isEmpty || isFocus(s)))
        .toList();
    final focusKeys = botRec.entries.where((e) => !e.key.contains(':') && e.key != 'all' && botRecFocus(e.value)).toList()
      ..sort((a, b) => b.value.sumR.compareTo(a.value.sumR));
    final allRec = botRec['all'];
    return wrap([
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Focus signals', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            Text(botRec.isEmpty
                ? (botRecError ?? 'Loading the bot track record...')
                : 'A signal is FOCUS when its strategy + direction already has $botFocusMinN+ closed bot paper trades with a net profit. '
                  'Bot record: ${allRec?.text ?? '-'}. Updated ${botRecAt == null ? '-' : hhmm(botRecAt!)}.',
                style: const TextStyle(fontSize: 12)),
            if (botRec.isNotEmpty && botRecError != null) Text(botRecError!, style: const TextStyle(fontSize: 11, color: Colors.orange)),
            if (botRec.isEmpty && sigFocusOnly) const Text('Focus cannot be checked without the bot record, so ALL signals are shown below.',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.orange)),
            if (ghViaApi) const Text('GitHub files are coming through the backup route (api.github.com), refreshed at most every 2 minutes.', style: TextStyle(fontSize: 11)),
            const SizedBox(height: 4),
            const Text('Tested on 2,201 past bot trades, using only data known at the time: all signals -70.8R, focus signals +81.4R '
                '(profit factor 1.21). Uses the bot\'s own stop and target. Past paper results, not a guarantee.', style: TextStyle(fontSize: 11)),
            const SizedBox(height: 6),
            if (focusKeys.isNotEmpty) const Text('Focus right now:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            for (final e in focusKeys.take(8))
              Text('${e.key.replaceAll('|', ' ')}: ${e.value.text}', style: const TextStyle(fontSize: 12, color: Colors.green)),
            Row(children: [
              const Expanded(child: Text('Show only focus signals', style: TextStyle(fontSize: 13))),
              Switch(value: sigFocusOnly, onChanged: (v) { setState(() => sigFocusOnly = v); savePaper(); }),
            ]),
          ]),
        ),
      ),
      botFocusCard(),
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
      if (list.isEmpty) message(sigFocusOnly && all.isNotEmpty ? 'No focus signal right now. Switch off "Show only focus signals" to see all ${all.length}.' : 'No signals yet. The bot posts here when a setup appears.'),
      for (final s in list) GestureDetector(onTap: () => openSignal(s, context), child: signalCard(s)),
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
            if (botRec.isNotEmpty)
              Builder(builder: (_) {
                final rec = recOf(s), coinRec = botRec['sym:${s['symbol']}|${s['side']}'];
                final f = botRecFocus(rec);
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${f ? 'FOCUS' : 'Not focus'}: ${s['strategy']} ${s['side']} ${rec == null ? 'has no closed trades yet' : rec.text}',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: f ? Colors.green : Colors.grey)),
                    if (coinRec != null) Text('${s['symbol']} ${s['side']}: ${coinRec.text}', style: const TextStyle(fontSize: 11)),
                  ]),
                );
              }),
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
      final r = await ghGet(url);
      if (r.statusCode != 200) {
        toast('Paper log is not published yet (HTTP ${r.statusCode}). It is published after a successful bot scan; it may contain only the CSV header until a paper position is opened.');
        return null;
      }
      return utf8.decode(r.bodyBytes);
    } catch (e) {
      toast('Could not download the log: ${netMsg(e)}');
      return null;
    }
  }

  Future<void> downloadBotLog() async {
    final csv = await fetchPaperCsv();
    if (csv == null) return;
    await downloadCsv('bot_paper_log.csv', csv);
  }

  Future<void> shareLog() async {
    final csv = await fetchPaperCsv();
    if (csv == null) return;
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/bot_paper_log.csv');
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
    toast('Copied ${csv.trim().split('\n').length - 1} log rows (including the header) to the clipboard.');
  }

  Widget exportCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Paper trading log', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('The bot\'s paper trades are part of the one ZIP with all logs (bot_paper_log.csv and bot_focus_account.csv).', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          zipButton(),
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

  Widget statBox(String title, String value, [Color? c]) => SizedBox(
        width: 112,
        child: Card(
          margin: const EdgeInsets.all(3),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 10)),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c)),
            ]),
          ),
        ),
      );

  /// Live table of open paper trades with the current market rate, P&L and a summary strip.
  Widget liveBoard(List<AppTrade> open) => ValueListenableBuilder<int>(valueListenable: liveTick, builder: (_, __, ___) => Builder(builder: (ctx) => liveBoardIn(open, ctx)));

  Widget liveBoardIn(List<AppTrade> allOpen, BuildContext ctx) {
    Color rc(double v) => v >= 0 ? Colors.green : Colors.red;
    String sgn(double v, [int d = 2]) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(d)}';
    // ---- filters and sorting
    final tfs = {for (final t in allOpen) t.tf}.toList()..sort((a, b) => tfList.indexOf(a).compareTo(tfList.indexOf(b)));
    if (ofTf != 'All' && !tfs.contains(ofTf)) ofTf = 'All';
    final coinQ = ofCoinCtl.text.trim().toUpperCase();
    bool pnlOk(AppTrade t) {
      if (ofPnl == 'All') return true;
      final p = livePnl(t, liveQuotes[t.coin]);
      if (p == null) return false;
      return ofPnl == 'Winning' ? p.usd > 0 : p.usd < 0;
    }
    final open = allOpen.where((t) => (ofSide == 'All' || (ofSide == 'BUY') == (t.side == 1)) && (ofTf == 'All' || t.tf == ofTf) && pnlOk(t) && (coinQ.isEmpty || t.coin.toUpperCase().contains(coinQ))).toList();
    double pv(AppTrade t) => livePnl(t, liveQuotes[t.coin])?.usd ?? 0.0;
    double tpv(AppTrade t) => livePnl(t, liveQuotes[t.coin])?.tpProgress ?? -999.0;
    double slv(AppTrade t) => livePnl(t, liveQuotes[t.coin])?.slDistPct ?? 999.0;
    if (ofSort == 'Best P&L') {
      open.sort((a, b) => pv(b).compareTo(pv(a)));
    } else if (ofSort == 'Worst P&L') {
      open.sort((a, b) => pv(a).compareTo(pv(b)));
    } else if (ofSort == 'Closest to TP') {
      open.sort((a, b) => tpv(b).compareTo(tpv(a)));
    } else if (ofSort == 'Closest to SL') {
      open.sort((a, b) => slv(a).compareTo(slv(b)));
    } else {
      open.sort((a, b) => b.opened.compareTo(a.opened));
    }
    final filtersOn = ofSide != 'All' || ofTf != 'All' || ofPnl != 'All' || coinQ.isNotEmpty;
    Widget chips(String label, List<String> values, String cur, void Function(String) apply) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            SizedBox(width: 62, child: Text(label, style: const TextStyle(fontSize: 11))),
            for (final v in values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(label: Text(v, style: const TextStyle(fontSize: 12)), selected: cur == v, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => apply(v))),
              ),
          ]),
        );
    var unreal = 0.0, tpSum = 0.0, slSum = 0.0, known = 0, winNow = 0, loseNow = 0;
    for (final t in open) {
      final p = livePnl(t, liveQuotes[t.coin]);
      if (p == null) continue;
      known++;
      unreal += p.usd;
      tpSum += p.tpProgress;
      slSum += p.slDistPct;
      if (p.usd > 0) winNow++;
      if (p.usd < 0) loseNow++;
    }
    final realized = trades.where((t) => !t.isOpen).fold<double>(0, (a, t) => a + t.pnl);
    final age = liveAt == null ? null : DateTime.now().difference(liveAt!).inSeconds;
    final feed = age == null ? 'WAITING' : age <= 12 ? 'LIVE' : age <= 60 ? 'STALE' : 'OFFLINE';
    final feedCol = feed == 'LIVE' ? Colors.green : feed == 'WAITING' ? Colors.grey : feed == 'STALE' ? Colors.orange : Colors.red;
    DataRow row(AppTrade t) {
      final q = liveQuotes[t.coin];
      final p = livePnl(t, q);
      final st = q == null ? 'OFFLINE' : q.status;
      final stc = st == 'LIVE' ? Colors.green : st == 'STALE' ? Colors.orange : Colors.red;
      final col = p == null ? null : rc(p.usd);
      return DataRow(onSelectChanged: (_) => openTrade(t, ctx), cells: [
        DataCell(Text('${t.coin} ${t.tf}', style: const TextStyle(fontWeight: FontWeight.w600))),
        DataCell(Text(q?.source ?? exchangeLabel(t.coin), style: const TextStyle(fontSize: 11))),
        DataCell(Text(t.side == 1 ? 'BUY' : 'SELL', style: TextStyle(color: t.side == 1 ? Colors.green : Colors.red, fontWeight: FontWeight.w700))),
        DataCell(Text('\$${t.notional.toStringAsFixed(0)}')),
        DataCell(Text(fmtPrice(t.entry))),
        DataCell(Text(p == null ? '-' : fmtPrice(p.px), style: TextStyle(fontWeight: FontWeight.w700, color: col))),
        DataCell(Text(fmtPrice(t.tp))),
        DataCell(Text(fmtPrice(t.sl))),
        DataCell(Text(p == null ? '-' : '${sgn(p.usd)} (${sgn(p.r)}R)', style: TextStyle(fontWeight: FontWeight.w600, color: col))),
        DataCell(Text(p == null ? '-' : '${sgn(p.pct)}%', style: TextStyle(color: col))),
        DataCell(Text(p == null ? '-' : '${p.tpProgress.toStringAsFixed(0)}%')),
        DataCell(Text(p == null ? '-' : '${p.slDistPct.toStringAsFixed(2)}% (${p.slDistR.toStringAsFixed(1)}R)')),
        DataCell(Text('OPEN $st', style: TextStyle(fontWeight: FontWeight.w600, color: stc))),
        DataCell(Text(sinceText(t.opened))),
        DataCell(TextButton(onPressed: () => closeTradeManually(t), child: const Text('Close', style: TextStyle(color: Colors.red)))),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 2),
        child: Row(children: [
          const Expanded(child: Text('Live open trades', style: TextStyle(fontWeight: FontWeight.w600))),
          Text(feed, style: TextStyle(fontWeight: FontWeight.w700, color: feedCol, fontSize: 12)),
          const SizedBox(width: 6),
          Text(liveAt == null ? 'no price yet' : 'updated ${hhmm(liveAt!)}:${liveAt!.second.toString().padLeft(2, '0')}', style: const TextStyle(fontSize: 11)),
          IconButton(onPressed: () => refreshLive(force: true), icon: const Icon(Icons.refresh, size: 20), tooltip: 'Refresh prices now'),
        ]),
      ),
      Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.filter_list, size: 18),
              const SizedBox(width: 4),
              Expanded(child: Text('Filter open trades: showing ${open.length} of ${allOpen.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
              if (filtersOn)
                TextButton(
                  onPressed: () { ofCoinCtl.clear(); setState(() { ofSide = 'All'; ofTf = 'All'; ofPnl = 'All'; }); },
                  child: const Text('Clear'),
                ),
            ]),
            TextField(
              controller: ofCoinCtl,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), prefixIcon: Icon(Icons.search, size: 18), hintText: 'Search coin, e.g. BTC'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 4),
            chips('Side', const ['All', 'BUY', 'SELL'], ofSide, (v) => ofSide = v),
            chips('Timeframe', ['All', ...tfs], ofTf, (v) => ofTf = v),
            chips('P&L now', const ['All', 'Winning', 'Losing'], ofPnl, (v) => ofPnl = v),
            chips('Sort', const ['Newest', 'Best P&L', 'Worst P&L', 'Closest to TP', 'Closest to SL'], ofSort, (v) => ofSort = v),
          ]),
        ),
      ),
      if (open.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text('No open trades match this filter.')),
      Wrap(children: [
        statBox('Open trades', '${open.length}'),
        statBox('Unrealized P&L', '${sgn(unreal)} \$', known == 0 ? null : rc(unreal)),
        statBox('Realized P&L', '${sgn(realized)} \$', rc(realized)),
        statBox('Winning now', '$winNow', Colors.green),
        statBox('Losing now', '$loseNow', Colors.red),
        statBox('Avg TP progress', known == 0 ? '-' : '${(tpSum / known).toStringAsFixed(0)}%'),
        statBox('Avg SL distance', known == 0 ? '-' : '${(slSum / known).toStringAsFixed(2)}%'),
      ]),
      Card(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            showCheckboxColumn: false,
            columnSpacing: 14,
            headingRowHeight: 34,
            dataRowMinHeight: 36,
            dataRowMaxHeight: 40,
            columns: const [
              DataColumn(label: Text('Symbol')), DataColumn(label: Text('Exchange')), DataColumn(label: Text('Side')), DataColumn(label: Text('Amount')),
              DataColumn(label: Text('Entry')), DataColumn(label: Text('Current rate')), DataColumn(label: Text('TP')),
              DataColumn(label: Text('SL')), DataColumn(label: Text('Unrealized P&L')), DataColumn(label: Text('P&L %')),
              DataColumn(label: Text('TP progress')), DataColumn(label: Text('SL distance')), DataColumn(label: Text('Status')),
              DataColumn(label: Text('Open for')), DataColumn(label: Text('Stop trade')),
            ],
            rows: [for (final t in open.take(openShown)) row(t)],
          ),
        ),
      ),
      if (open.length > 30)
        Row(children: [
          if (open.length > openShown)
            TextButton(onPressed: () => setState(() => openShown += 30), child: Text('Show 30 more (${open.length - openShown} hidden)')),
          if (openShown > 30) TextButton(onPressed: () => setState(() => openShown = 30), child: const Text('Show less')),
        ]),
      const Padding(
        padding: EdgeInsets.fromLTRB(4, 2, 4, 0),
        child: Text('Rates are polled every 3 seconds (not a WebSocket stream). Binance coins use the best bid/ask: a BUY is valued at the bid and a SELL at the ask, minus the 0.05R fee. '
            'Tap a row to open that trade on the Markets chart with its entry, SL and TP lines; tap Close to stop it at the current rate. Forex, gold and oil use Yahoo Finance and can lag. LIVE under 12 s old, STALE under 60 s, otherwise OFFLINE. Open trades are not counted as wins or losses until they close.',
            style: TextStyle(fontSize: 10)),
      ),
    ]);
  }

  /// Trading results (profit) shown separately from directional accuracy (did price at least move our way).
  Widget perfDashboard() {
    final done = trades.where((t) => !t.isOpen).toList()
      ..sort((a, b) => (a.closed ?? a.opened).compareTo(b.closed ?? b.opened));
    if (done.isEmpty) return const SizedBox.shrink();
    final wins = done.where((t) => t.r > 0).toList(), losses = done.where((t) => t.r <= 0).toList();
    final net = done.fold<double>(0, (a, t) => a + t.pnl);
    final gw = wins.fold<double>(0, (a, t) => a + t.pnl), gl = -losses.fold<double>(0, (a, t) => a + t.pnl);
    final pf = gl == 0 ? (gw > 0 ? 99.0 : 0.0) : gw / gl;
    var eq = paperStart, peak = paperStart, maxDd = 0.0;
    for (final t in done) {
      eq += t.pnl;
      if (eq > peak) peak = eq;
      if (peak > 0) maxDd = math.max(maxDd, (peak - eq) / peak * 100);
    }
    final tpN = done.where((t) => t.reason == 'TP').length, slN = done.where((t) => t.reason == 'SL').length;
    final dirOk = done.where((t) => t.mfe >= 0.5).length;
    final expR = done.fold<double>(0, (a, t) => a + t.r) / done.length;
    final avgW = wins.isEmpty ? 0.0 : gw / wins.length, avgL = losses.isEmpty ? 0.0 : -gl / losses.length;
    final open = trades.where((t) => t.isOpen).length, auto = trades.where((t) => t.source == 'auto').length;
    Color rc(double v) => v >= 0 ? Colors.green : Colors.red;
    String sgn(double v, [int d = 2]) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(d)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Performance dashboard', style: TextStyle(fontWeight: FontWeight.w700)),
          Wrap(children: [
            statBox('Signals (session)', '$paperSignals'),
            statBox('Auto trades opened', '$auto'),
            statBox('Open now', '$open'),
            statBox('Closed', '${done.length}'),
            statBox('Wins', '${wins.length}', Colors.green),
            statBox('Losses', '${losses.length}', Colors.red),
            statBox('Win rate', '${(100 * wins.length / done.length).toStringAsFixed(1)}%'),
            statBox('TP rate', '${(100 * tpN / done.length).toStringAsFixed(1)}%'),
            statBox('SL rate', '${(100 * slN / done.length).toStringAsFixed(1)}%'),
            statBox('Avg win', '${sgn(avgW)} \$', Colors.green),
            statBox('Avg loss', '${sgn(avgL)} \$', Colors.red),
            statBox('Net P&L', '${sgn(net)} \$', rc(net)),
            statBox('Profit factor', pf.toStringAsFixed(2), pf >= 1 ? Colors.green : Colors.red),
            statBox('Expectancy', '${sgn(expR, 3)} R', rc(expR)),
            statBox('Max drawdown', '${maxDd.toStringAsFixed(1)}%', maxDd > 10 ? Colors.red : null),
          ]),
          const SizedBox(height: 4),
          Text('Direction right (price moved 0.5R our way): ${(100 * dirOk / done.length).toStringAsFixed(0)}% of trades. Profitable: ${(100 * wins.length / done.length).toStringAsFixed(0)}%. '
              'Both are shown because a signal can point the right way and still lose money after stops and fees.', style: const TextStyle(fontSize: 11)),
          if (done.length < 100) Text('Only ${done.length} closed trades: results below 100 trades are mostly noise.', style: const TextStyle(fontSize: 11, color: Colors.orange)),
        ]),
      ),
    );
  }

  /// Signals the gate turned into NO TRADE, with the reason.
  Widget gateRejectCard() {
    if (gateRejects.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('NO TRADE: signals the quality gate rejected', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          for (final g in gateRejects.take(12))
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('${hhmm(g.at)}  ${g.coin} ${g.tf} ${g.side == 1 ? 'BUY' : 'SELL'}: ${g.reason}', style: const TextStyle(fontSize: 11)),
            ),
        ]),
      ),
    );
  }

  /// Markets screen: shows why auto paper trading would not take the current coin/timeframe (only if the scan has checked it).
  Widget gateNote() {
    final v = gateLast['$marketSymbol|$marketInterval'];
    if (v == null) return const SizedBox.shrink();
    final i = v.indexOf('|');
    final when = v.substring(0, i), why = v.substring(i + 1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: Text(why == 'OK' ? 'Signal gate ($when): passed, auto paper trading would take it.' : 'NO TRADE ($when): $why',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: why == 'OK' ? Colors.green : Colors.orange)),
    );
  }

  Map<String, List<AppTrade>> tradesByIndicator() {
    final m = <String, List<AppTrade>>{};
    for (final t in trades.where((t) => !t.isOpen)) {
      for (final n in t.inds.split('|')) {
        if (n.isEmpty) continue;
        m.putIfAbsent(n, () => []).add(t);
      }
    }
    return m;
  }

  Widget focusCard() {
    final f = focusMap;
    final n = edgeSample(trades).length;
    String nm(String k) { final p = k.split('|'); if (p.length == 2) return 'All ${p[1]} trades'; return p[0] == 'i' ? 'Indicator: ${p[1]} ${p[2]}' : '${p[1]} ${p[2]}'; }
    int rel(MapEntry<String, Edge> e) => indicatorRel(e.value, f['s|${e.key.split('|').last}']);
    List<MapEntry<String, Edge>> pick(String pre, bool Function(Edge) ok, bool best) {
      final l = f.entries.where((e) => e.key.startsWith(pre) && ok(e.value)).toList()
        ..sort((a, b) => best ? b.value.sumR.compareTo(a.value.sumR) : a.value.sumR.compareTo(b.value.sumR));
      return l.take(6).toList();
    }
    Widget row(MapEntry<String, Edge> e) {
      final d = e.value;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(nm(e.key), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          Text('${d.n} tr, ${d.winPct.toStringAsFixed(0)}%, halves ${d.r1.toStringAsFixed(1)} / ${d.r2.toStringAsFixed(1)}  ',
              style: const TextStyle(fontSize: 11)),
          Text('${d.sumR >= 0 ? '+' : ''}${d.sumR.toStringAsFixed(1)} R',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: d.sumR >= 0 ? Colors.green : Colors.red)),
        ]),
      );
    }
    Widget sect(String title, List<MapEntry<String, Edge>> l) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 8, bottom: 2), child: Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
          if (l.isEmpty) const Text('None yet', style: TextStyle(fontSize: 11)) else ...l.map(row),
        ]);
    final proven = pick('c|', (e) => e.proven, true);
    final losing = pick('c|', (e) => e.losing, false);
    final indBetter = f.entries.where((e) => e.key.startsWith('i|') && rel(e) > 0).take(6).toList();
    final indWorse = f.entries.where((e) => e.key.startsWith('i|') && rel(e) < 0).take(6).toList();
    final sides = f.entries.where((e) => e.key.startsWith('s|')).toList();
    final leaders = pick('c|', (e) => e.n >= 5 && e.sumR > 0, true);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Focus: profitable coins, directions, indicators', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          Text('Based on $n closed trades (manual closes left out). A combo counts as proven only with $focusMinN+ trades, profit factor above 1.1 '
              'and profit in both the older and newer half of its trades.', style: const TextStyle(fontSize: 11)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final o in const {'Off': 0, 'Skip losers': 1, 'Proven only': 2}.entries)
              ChoiceChip(label: Text(o.key), selected: focusMode == o.value, onSelected: (_) { setState(() => focusMode = o.value); savePaper(); }),
          ]),
          Text(focusMode == 0 ? 'Off: all signals that pass the gate are traded, so every combo keeps collecting data.'
              : focusMode == 1 ? 'Skip losers: no new auto trades on a coin + direction that lost in both halves, or when most agreeing indicators did worse than average.'
              : proven.isEmpty
                  ? 'Proven only: no coin + direction is proven yet, so NO auto trades will open. Use Off or Skip losers.'
                  : 'Proven only: auto trades only on the ${proven.length} proven coin + direction combos below.',
              style: TextStyle(fontSize: 11, color: focusMode == 2 && proven.isEmpty ? Colors.red : null, fontWeight: focusMode == 2 && proven.isEmpty ? FontWeight.w700 : null)),
          sect('Direction overall', sides),
          sect('Proven profitable coins + direction', proven),
          sect('Coins + direction losing in both halves', losing),
          sect('Indicators better than average (both halves)', indBetter),
          sect('Indicators worse than average (both halves)', indWorse),
          sect('Leading coins + direction (5+ trades, not proven yet)', leaders),
          const Padding(padding: EdgeInsets.only(top: 6), child: Text('Full table: Export > app_profit_analysis.csv (first_half_r, second_half_r, verdict columns).', style: TextStyle(fontSize: 11))),
        ]),
      ),
    );
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
      botFocusCard(),
      newsTradesCard(),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Auto paper trading', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
              Switch(value: autoPaper, onChanged: setAutoPaper),
            ]),
            const Text('Trade source', style: TextStyle(fontSize: 12)),
            Wrap(spacing: 8, children: [
              for (final o in const {'Bot focus signals': 1, 'App indicators': 0, 'Both': 2}.entries)
                ChoiceChip(label: Text(o.key), selected: paperSource == o.value, onSelected: (_) { setState(() => paperSource = o.value); savePaper(); }),
            ]),
            Text(paperSource == 0
                ? 'App indicators: the app\'s own signals. Your uploaded app trades lost (426 trades, -37.6R) and no coin or direction filter fixed it.'
                : 'Bot focus: copies fresh GitHub bot signals (30 min or newer) whose strategy + direction is profitable in the bot\'s own record. '
                  'Uses the bot\'s stop and target (mostly 1:2): at 1:1 the same signals were about break-even. Crypto only.',
                style: const TextStyle(fontSize: 11)),
            if (paperSource != 0 && botStatus.isNotEmpty) Text(botStatus, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            if (paperSource != 0 && botRecError != null) Text(botRecError!, style: const TextStyle(fontSize: 11, color: Colors.orange)),
            if (autoPaper && (paperMinQ == 0 || paperMinAdx == 0 || paperMinScore < 0.35))
              Container(
                margin: const EdgeInsets.only(top: 6, bottom: 4),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.orange.withOpacity(.15), borderRadius: BorderRadius.circular(8)),
                child: const Text('Filters are loosened. With the quality filter Off, late and stretched entries are NOT rejected, and in your own data those entries lost most of the money. '
                    'Recommended: Strong (0.5), ADX 25, quality 4 of 5.', style: TextStyle(fontSize: 12)),
              ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Mean-reversion BUY (experimental)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: const Text('Buys oversold dips when the Z-score and another stretch indicator agree. Tracked separately as "App MR" so it never mixes with the trend results. SELL is off because the Lab found it losing.', style: TextStyle(fontSize: 11)),
              value: paperMr,
              onChanged: (v) { setState(() => paperMr = v); savePaper(); },
            ),
            Text(autoPaper
                ? 'ON. When a candle closes on any chosen timeframe, the app checks the top $paperCoins coins and opens virtual trades from the signals that pass your filters. Works while the app is open or minimized. Swiping it away from recent apps stops in-app trading (Android rule); the Bot focus account and the Experiments tab run on GitHub and never stop.'
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
              for (final n in [20, 50, 100, 200, 500, 1000000])
                ChoiceChip(label: Text(n >= 1000000 ? 'No limit' : '$n'), selected: paperMaxOpen == n, onSelected: (_) { setState(() => paperMaxOpen = n); savePaper(); }),
            ]),
            const SizedBox(height: 8),
            const Text('Target (reward : risk)', style: TextStyle(fontSize: 12)),
            Wrap(spacing: 8, children: [
              for (final o in const {'1:1': 1.0, '1:1.5': 1.5, '1:2': 2.0}.entries)
                ChoiceChip(label: Text(o.key), selected: planRR == o.value, onSelected: (_) { rrCtl.clear(); setState(() => planRR = o.value); savePaper(); }),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              const Text('Custom  1 : ', style: TextStyle(fontSize: 13)),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: rrCtl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: 'e.g. 1.25'),
                  onChanged: (v) {
                    final x = double.tryParse(v.trim().replaceAll(',', '.'));
                    if (x != null && x >= 0.5 && x <= 10) { setState(() => planRR = x); savePaper(); }
                    else if (v.trim().isEmpty) { setState(() => planRR = 1.0); savePaper(); }
                  },
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(child: Text('0.5 to 10. Empty = 1:1', style: TextStyle(fontSize: 11))),
            ]),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Now: 1:${fmtRR(planRR)}. Break-even win rate about ${(105 / (planRR + 1)).toStringAsFixed(1)}% (fees included). '
                  '1:1 needs 52.5%, 1:2 needs 35% but wins less often. Applies to new trades only; compare them in "By target" below.', style: const TextStyle(fontSize: 11)),
            ),
            const SizedBox(height: 8),
            const Text('Amount per trade (USD)', style: TextStyle(fontSize: 12)),
            TextField(
              controller: paperAmountCtl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), prefixText: '\$ ', hintText: 'Empty = risk 1% of the paper account'),
              onChanged: (v) {
                final x = double.tryParse(v.trim().replaceAll(',', '.'));
                setState(() => paperAmount = x != null && x > 0 ? x : 0);
                savePaper();
              },
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  paperAmount > 0
                      ? 'Each new trade uses \$${paperAmount.toStringAsFixed(2)} of position size. Profit and loss = the price move in % x this amount. Applies to new trades only; open trades keep their size.'
                      : 'Auto: each new trade risks 1% of the paper account (the stop-out loss), so the position size changes with each stop distance.',
                  style: const TextStyle(fontSize: 11)),
            ),
            const SizedBox(height: 6),
            const Text('Stop and target come from the same trade plan shown in Markets. Trades use a 1:1 reward to risk, one open trade per coin and timeframe, and none open during a high-impact news window. Same-candle stop and target counts as a loss, and 0.05R is charged for fees.', style: TextStyle(fontSize: 11)),
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
              Text('Hit target ${st.tp}, hit stop ${st.sl}, timed out ${st.timeouts}, closed by you ${st.manual}', style: const TextStyle(fontSize: 12)),
            ],
          ]),
        ),
      ),
      perfDashboard(),
      focusCard(),
      gateRejectCard(),
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
      if (open.isNotEmpty) liveBoard(open),
      if (st.n > 0) ...[
        group('By strategy', by(stratLabel)),
        group('By target (reward:risk)', by((t) => '1:${fmtRR(t.plannedRR)}')),
        group('By timeframe', by((t) => t.tf)),
        group('By trading style', by((t) => styleOf(t.tf))),
        group('By direction', by((t) => t.side == 1 ? 'BUY' : 'SELL')),
        group('By signal strength', by((t) => t.score.abs() >= .5 ? 'Strong (0.5+)' : t.score.abs() >= .35 ? 'Medium (0.35-0.5)' : 'Weak (0.2-0.35)')),
        group('By quality score', by((t) => t.quality == 0 ? 'Unfiltered' : 'Quality ${t.quality} of 5')),
        group('By ADX range', by((t) => t.adx == null ? 'ADX not recorded' : t.adx! < 20 ? 'ADX under 20' : t.adx! < 25 ? 'ADX 20-25' : t.adx! < 30 ? 'ADX 25-30' : t.adx! < 40 ? 'ADX 30-40' : 'ADX 40+')),
        group('By market regime', by((t) => t.regime.isEmpty ? 'Not recorded' : t.regime)),
        group('By indicator agreeing at entry', tradesByIndicator()),
        group('By coin', by((t) => t.coin)),
      ],
      if (closed.isNotEmpty) ...[
        const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 2), child: Text('Recent closed trades', style: TextStyle(fontWeight: FontWeight.w600))),
        for (final t in closed.take(25))
          Builder(builder: (ctx) => ListTile(
            onTap: () => openTrade(t, ctx),
            dense: true,
            title: Text('${t.coin} ${t.side == 1 ? 'BUY' : 'SELL'} (${t.tf})  ${t.reason}${t.ambiguous ? ' *' : ''}'),
            leading: Icon(t.r > 0 ? Icons.check_circle : Icons.cancel, color: t.r > 0 ? Colors.green : Colors.red, size: 18),
            subtitle: Text('CLOSED ${ago(t.closed?.toIso8601String())} at ${fmtPrice(t.exitPx)}, ${t.verdict}'),
            trailing: Text('${sgn(t.r)} R', style: TextStyle(fontWeight: FontWeight.w600, color: rc(t.r))),
          )),
        const Text('* stop and target were both touched in the same candle, counted as a stop.', style: TextStyle(fontSize: 11)),
      ],
      if (trades.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No trades yet. Turn on Auto paper trading and trades will appear here.', textAlign: TextAlign.center)),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Download all logs', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('One ZIP file with everything: app trades, profit analysis, trade indicators, news trades and headlines, the bot log and bot focus account, the Lab files and the Experiment lab files.', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            zipButton(),
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
    bool inStyle(LabSnap x) => labStyle == 'All' || styleOf(x.tf) == labStyle;
    bool inSide(int side) => labSide == 'All' || (labSide == 'BUY') == (side == 1);
    // one stats row per Lab indicator, from the scored and the still-open signals
    final stats = {for (final n in labKeep) n: LabStat()};
    for (final x in labRows) {
      if (!inStyle(x)) continue;
      x.votes.forEach((n, sd) { if (inSide(sd)) stats[n]?.add(LabTrade(x, sd, false)); });
    }
    for (final x in labPending) {
      if (!inStyle(x)) continue;
      x.votes.forEach((n, sd) { if (inSide(sd)) stats[n]?.add(LabTrade(x, sd, true)); });
    }
    final order = labKeep.where((n) => labVersion == 'All' || (labVersion == 'With trend') == n.endsWith(labTrendSuffix)).toList()
      ..sort((p, q) => stats[q]!.r.compareTo(stats[p]!.r));
    Color rc(double v) => v >= 0 ? Colors.green : Colors.red;
    String sg(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}';
    String when(DateTime t) => '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')} ${hhmm(t)}';
    // trades of the selected indicator, newest first (open ones on top)
    final sel = labSel;
    final list = <LabTrade>[];
    if (sel != null) {
      for (final x in labPending.reversed) {
        final sd = x.votes[sel];
        if (sd != null && inStyle(x) && inSide(sd)) list.add(LabTrade(x, sd, true));
      }
      for (final x in labRows.reversed) {
        final sd = x.votes[sel];
        if (sd != null && inStyle(x) && inSide(sd)) list.add(LabTrade(x, sd, false));
      }
    }
    Map<String, LabStat> splitBy(String Function(LabTrade) f) {
      final m = <String, LabStat>{};
      for (final x in list) {
        m.putIfAbsent(f(x), () => LabStat()).add(x);
      }
      return m;
    }
    return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(12), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('Signal Lab (${labBase.length} indicators + trend versions)', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
              Switch(value: labOn, onChanged: setLabOn),
            ]),
            Text('Tests only: ${labBase.join(', ')}. Each also has a "+ trend" version that keeps only BUY signals while price is above '
                'EMA 200 and SELL signals while it is below (same timeframe). Every signal is a trade: entry at the signal candle\'s close, target 1.5 ATR, '
                'stop 1.5 ATR (1:1), judged over the next $labHorizonBars candles, 0.05R fee. Timed out = neither hit, closed at the last price. '
                'An indicator that stays in its zone for several candles gives a signal on each of them.', style: const TextStyle(fontSize: 12)),
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
      Wrap(spacing: 8, children: [for (final x in styles) ChoiceChip(label: Text(x), selected: labStyle == x, onSelected: (_) => setState(() { labStyle = x; labShown = 50; }))]),
      Wrap(spacing: 8, children: [for (final x in const ['All', 'BUY', 'SELL']) ChoiceChip(label: Text(x), selected: labSide == x, onSelected: (_) => setState(() { labSide = x; labShown = 50; }))]),
      Wrap(spacing: 8, children: [for (final x in const ['All', 'Plain', 'With trend']) ChoiceChip(label: Text(x), selected: labVersion == x, onSelected: (_) => setState(() => labVersion = x))]),
      const Padding(padding: EdgeInsets.fromLTRB(4, 10, 4, 2), child: Text('Indicators (tap one to see all its trades, tap a trade to see it on the chart)', style: TextStyle(fontWeight: FontWeight.w600))),
      for (final n in order)
        Card(
          color: labSel == n ? Theme.of(context).colorScheme.primaryContainer : null,
          child: ListTile(
            dense: true,
            onTap: () => setState(() { labSel = labSel == n ? null : n; labShown = 50; }),
            title: Text(n, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(stats[n]!.n + stats[n]!.open == 0 ? 'No signals yet' : stats[n]!.text, style: const TextStyle(fontSize: 12)),
            trailing: Text('${sg(stats[n]!.r)}R', style: TextStyle(fontWeight: FontWeight.w700, color: rc(stats[n]!.r))),
          ),
        ),
      if (sel != null) ...[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('$sel: all trades', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
              ]),
              for (final g in [
                {'title': 'By direction', 'm': splitBy((x) => x.side == 1 ? 'BUY' : 'SELL')},
                {'title': 'By timeframe', 'm': splitBy((x) => x.s.tf)},
              ]) ...[
                Padding(padding: const EdgeInsets.only(top: 6), child: Text('${g['title']}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                for (final e in (g['m'] as Map<String, LabStat>).entries)
                  Text('${e.key}: ${e.value.text}', style: TextStyle(fontSize: 12, color: e.value.n == 0 ? null : rc(e.value.r))),
              ],
              const SizedBox(height: 6),
              if (list.isEmpty) const Text('No trades yet for this filter.', style: TextStyle(fontSize: 12)),
              for (final x in list.take(labShown))
                InkWell(
                  onTap: () => openLevels(x.s.coin, x.s.tf, x.s.t0, x.s.price, x.sl, x.tp, context),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Text('${when(x.s.t0)}  ${x.side == 1 ? 'BUY' : 'SELL'} ${x.s.coin} ${x.s.tf}\n'
                          'Entry ${fmtPrice(x.s.price)}  TP ${fmtPrice(x.tp)}  SL ${fmtPrice(x.sl)}'
                          '${x.open ? '  (scored ${hhmm(x.s.t0.add(Duration(milliseconds: barMs(x.s.tf) * labHorizonBars)))})' : ''}',
                          style: const TextStyle(fontSize: 12)),
                    ),
                    Text(x.open ? 'OPEN' : '${x.result}\n${sg(x.r)}R', textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                            color: x.open ? Colors.grey : x.result == 'WIN' ? Colors.green : x.result == 'LOSS' ? Colors.red : Colors.orange)),
                  ]),
                ),
              if (list.length > labShown)
                TextButton(onPressed: () => setState(() => labShown += 50), child: Text('Show 50 more (${list.length - labShown} left)')),
            ]),
          ),
        ),
      ],
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Download all logs', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('The Lab accuracy table, snapshots and every Lab trade are inside the one ZIP with all logs.', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            zipButton(),
            Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: resetLab, icon: const Icon(Icons.delete_outline), label: const Text('Reset Lab'))),
          ]),
        ),
      ),
      const Padding(padding: EdgeInsets.only(top: 8), child: Text('The Lab collects only while the app is open or minimized. The Experiments tab tests 40 indicators on GitHub 24/7. '
          'A short good run can be luck: trust an indicator only after hundreds of trades.', style: TextStyle(fontSize: 11))),
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
      length: 7,
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
            Tab(text: 'Signals'),
            Tab(text: 'Alerts'),
            Tab(text: 'Paper'),
            Tab(text: 'Lab'),
            Tab(text: 'Report'),
            Tab(text: 'Experiments'),
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
              child: TabBarView(children: [marketTab(), signalsTab(), alertsTab(), paperTab(), labTab(), reportTab(), expTab()]),
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

class ChartMark {
  final String label;
  final double price;
  final Color color;
  const ChartMark(this.label, this.price, this.color);
}

class CandlePainter extends CustomPainter {
  final List<Candle> candles;
  final bool dark;
  final List<double> sup, res;
  final List<ChartMark> marks;   // selected paper trade: entry, stop and target lines
  CandlePainter(this.candles, this.dark, [this.sup = const [], this.res = const [], this.marks = const []]);
  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.width <= 0 || size.height <= 0) return;
    var minV = candles.map((c)=>c.low).reduce(math.min);
    var maxV = candles.map((c)=>c.high).reduce(math.max);
    for (final m in marks) { minV = math.min(minV, m.price); maxV = math.max(maxV, m.price); }   // keep the trade levels on screen
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
    void level(double v, Color col, [String label = '']) {
      if (v < minV || v > maxV) return;
      final yy = y(v);
      final p = Paint()..color = col.withOpacity(.75)..strokeWidth = 1;
      for (double x = 0; x < size.width; x += 10) { canvas.drawLine(Offset(x, yy), Offset(math.min(x + 5, size.width), yy), p); }
      tp.text = TextSpan(text: label.isEmpty ? fmtPrice(v) : '$label ${fmtPrice(v)}', style: TextStyle(fontSize: 10, color: col, fontWeight: label.isEmpty ? FontWeight.normal : FontWeight.w700));
      tp.layout();
      tp.paint(canvas, Offset(size.width - tp.width - 2, yy - 12));
    }
    for (final v in sup) { level(v, Colors.green); }
    for (final v in res) { level(v, Colors.red); }
    for (final m in marks) { level(m.price, m.color, m.label); }
    tp.text=TextSpan(text:fmtPrice(maxV),style:TextStyle(fontSize:10,color:dark?Colors.white70:Colors.black54)); tp.layout(); tp.paint(canvas,Offset(2,0));
    tp.text=TextSpan(text:fmtPrice(minV),style:TextStyle(fontSize:10,color:dark?Colors.white70:Colors.black54)); tp.layout(); tp.paint(canvas,Offset(2,size.height-14));
  }
  @override
  bool shouldRepaint(covariant CandlePainter oldDelegate) => true;
}

extension TakeLastList<E> on List<E> {
  List<E> takeLast(int count) => skip(math.max(0, length-count)).toList();
}
