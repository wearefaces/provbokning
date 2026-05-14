// Native platforms: install the Dio cookie manager (in-memory jar).
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

void configurePlatform(Dio dio) {
  final jar = CookieJar();
  dio.interceptors.add(CookieManager(jar));
}
