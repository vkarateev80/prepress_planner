/// Тяжёлые вычисления на VM/desktop: изолят.
library;

import 'dart:isolate';

Future<T> heavy<T>(T Function() fn) => Isolate.run(fn);
