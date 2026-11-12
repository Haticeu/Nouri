import 'package:flutter_test/flutter_test.dart';
import 'package:nouri/core/i18n.dart';

void main() {
  tearDown(() => appLang = 'en');

  test('English device: text unchanged, placeholders filled', () {
    appLang = 'en';
    expect(t('Scan a meal'), 'Scan a meal');
    expect(t('Logged {0} of 7 days', [5]), 'Logged 5 of 7 days');
    expect(tServer('Your dietitian updated your protein target to 110 g'), 'Your dietitian updated your protein target to 110 g');
  });

  test('Turkish device: UI strings and placeholders', () {
    appLang = 'tr';
    expect(t('Scan a meal'), 'Öğün tara');
    expect(t('Add to {0}', [t('Breakfast')]), 'Ekle: Kahvaltı');
    expect(t('Something not in the dictionary'), 'Something not in the dictionary');
  });

  test('Turkish device: server sentences with variable parts', () {
    appLang = 'tr';
    expect(tServer('Your dietitian updated your protein target to 110 g'), 'Diyetisyenin protein hedefini 110 g olarak güncelledi');
    expect(tServer('Your dietitian assigned you the meal plan "Balanced Mediterranean week"'),
        'Diyetisyenin sana "Balanced Mediterranean week" planını atadı');
    expect(tServer('Tip from Dr. Selin Kaya'), 'Tavsiye · Dr. Selin Kaya');
    expect(tServer('invite is invalid or has expired'), 'Davet kodu geçersiz ya da süresi dolmuş.');
    expect(tServer('Hi! See you Thursday.'), 'Hi! See you Thursday.'); // user messages untouched
  });
}
