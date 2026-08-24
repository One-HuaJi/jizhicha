import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/captcha_ocr.dart';

void main() {
  test('验证码文本只保留严格 4 位小写字母数字候选', () {
    expect(CaptchaOcr.normalize('\n AbC1 \n'), 'abc1');
    expect(CaptchaOcr.normalize('识别结果: x9y8'), 'x9y8');
    expect(CaptchaOcr.normalize('r kj 9'), 'rkj9');
    expect(CaptchaOcr.normalize('a-b-c-1'), 'abc1');
    expect(CaptchaOcr.normalize('abc'), isNull);
    expect(CaptchaOcr.normalize('abcde'), isNull);
  });

  test('ddddocr 字符索引经过 CTC 解码得到四位验证码', () {
    expect(
      CaptchaOcr.decodeCharacterIndices([0, 6979, 6979, 0, 7721, 806, 7136]),
      '83rw',
    );
    expect(CaptchaOcr.decodeCharacterIndices([7136, 6977, 1066, 7198]), 'w5ba');
    expect(CaptchaOcr.decodeCharacterIndices([2089, 3466, 1107, 4730]), 'lscz');
  });

  test('模型输出不是完整四位小写字母数字时拒绝自动填入', () {
    expect(CaptchaOcr.decodeCharacterIndices([2089, 3466, 1107]), isNull);
    expect(
      CaptchaOcr.decodeCharacterIndices([2089, 3466, 1107, 4730, 806]),
      isNull,
    );
    expect(CaptchaOcr.decodeCharacterIndices([2089, 9999, 1107, 4730]), isNull);
  });
}
