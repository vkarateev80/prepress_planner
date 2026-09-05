/// Тяжёлые вычисления: отдельный изолят на desktop, прямой вызов на web
/// (в браузере изолятов нет). Общий API один.
library;

import 'isolates_io.dart' if (dart.library.html) 'isolates_web.dart' as impl;

Future<T> heavy<T>(T Function() fn) => impl.heavy(fn);
