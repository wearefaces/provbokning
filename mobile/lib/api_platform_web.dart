// Web platform: enable XHR credentials so the Flask session cookie is sent.
import 'package:dio/dio.dart';
import 'package:dio/browser.dart';

void configurePlatform(Dio dio) {
  (dio.httpClientAdapter as BrowserHttpClientAdapter).withCredentials = true;
}
