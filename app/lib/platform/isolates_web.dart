/// Тяжёлые вычисления на web: изолятов нет — выполняем на главном потоке
/// (асинхронно, чтобы не блокировать event loop).
library;

Future<T> heavy<T>(T Function() fn) async => fn();
