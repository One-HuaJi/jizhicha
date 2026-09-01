import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/credential_store.dart';
import 'package:jizhicha/schedule_time.dart';

void main() {
  group('parseScheduleTimeMode', () {
    test('识别三种模式', () {
      expect(parseScheduleTimeMode('automatic'), ScheduleTimeMode.automatic);
      expect(
        parseScheduleTimeMode('springAutumnWinter'),
        ScheduleTimeMode.springAutumnWinter,
      );
      expect(parseScheduleTimeMode('summer'), ScheduleTimeMode.summer);
    });

    test('未知值回退到 automatic', () {
      expect(parseScheduleTimeMode(null), ScheduleTimeMode.automatic);
      expect(parseScheduleTimeMode('garbage'), ScheduleTimeMode.automatic);
    });
  });

  group('ScheduleTimeTable.sublessonNumbers', () {
    test('解析小节编号', () {
      expect(
        ScheduleTimeTable.sublessonNumbers('第一大节 (01,02小节)'),
        [1, 2],
      );
      expect(
        ScheduleTimeTable.sublessonNumbers('第五大节 (09,10小节)'),
        [9, 10],
      );
    });

    test('无括号或越界小节返回空', () {
      expect(ScheduleTimeTable.sublessonNumbers('第一大节'), isEmpty);
      expect(ScheduleTimeTable.sublessonNumbers('第一大节 (99小节)'), isEmpty);
    });
  });

  group('isEducationPasswordSafeToStore', () {
    test('至少 8 位且含字母和数字', () {
      expect(isEducationPasswordSafeToStore('abcd1234'), isTrue);
      expect(isEducationPasswordSafeToStore('a1b2c3d4'), isTrue);
    });

    test('过短 / 缺字母 / 缺数字 都不安全', () {
      expect(isEducationPasswordSafeToStore('short1'), isFalse);
      expect(isEducationPasswordSafeToStore('abcdefgh'), isFalse);
      expect(isEducationPasswordSafeToStore('12345678'), isFalse);
    });
  });
}
