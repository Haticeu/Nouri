// The foods Nouri ships with. Every nutrition number is taken from USDA
// FoodData Central by `fdc` id when the seed is built (build_foods.mjs); this
// file only holds names, search aliases and how to map USDA portions to
// Turkish household measures. Nothing here is a nutrition value.
//
//   f(key, fdc, name_tr, name_en, category, options)
//     fdc       USDA FDC id, or null for a dish with no USDA source (a `todo`
//               row: no values until a dietitian fills them in)
//     approx    the USDA food is a close stand-in, not the same recipe (e.g.
//               FNDDS "Soup, lentil" for mercimek çorbası); shown in source_note
//     aliases   extra search words (Turkish and English)
//     liquid    drinks: adds ml and çay bardağı units
//     portionsFrom  take household portions from another FDC record of the same
//               food (Foundation foods often have nutrients but no portions)
//     skip      portion units not to derive (e.g. 'su bardağı' for bread)
//     pick      regex choosing which USDA portion becomes `adet`

const foods = [];
const f = (key, fdc, tr, en, category, o = {}) => foods.push({ key, fdc: fdc && String(fdc), tr, en, category, ...o });
const approx = (fdc, what) => ({ fdc, approx: what });

// ---------------------------------------------------------------------------
// Eggs
// ---------------------------------------------------------------------------
f('egg_boiled', 173424, 'Haşlanmış yumurta', 'Boiled egg', 'eggs', { aliases: ['yumurta', 'katı yumurta', 'rafadan', 'egg', 'hard-boiled egg'], portionsFrom: 171287, skip: ['su bardağı', 'yemek kaşığı'] });
f('egg_fried', 173423, 'Sahanda yumurta', 'Fried egg', 'eggs', { aliases: ['yağda yumurta', 'tavada yumurta', 'göz yumurta', 'fried eggs'], portionsFrom: 171287, skip: ['su bardağı'] });
f('egg_scrambled', 172187, 'Çırpılmış yumurta', 'Scrambled eggs', 'eggs', { aliases: ['scrambled egg'], skip: ['adet'] });
f('omelette', 172185, 'Omlet', 'Omelette', 'eggs', { aliases: ['omelet', 'sade omlet'] });
f('egg_raw', 171287, 'Yumurta (çiğ)', 'Egg, raw', 'eggs', { aliases: ['çiğ yumurta', 'raw egg'], skip: ['su bardağı'] });
f('egg_white', 172183, 'Yumurta akı', 'Egg white', 'eggs', { aliases: ['egg whites'] });

// ---------------------------------------------------------------------------
// Bread and grains
// ---------------------------------------------------------------------------
f('bread_white', 174924, 'Beyaz ekmek', 'White bread', 'bread_grains', { aliases: ['ekmek', 'francala', 'somun', 'bread', 'white bread'], skip: ['su bardağı'] });
f('bread_whole_wheat', 172688, 'Tam buğday ekmeği', 'Whole-wheat bread', 'bread_grains', { aliases: ['tam buğday', 'kepekli ekmek', 'esmer ekmek', 'whole wheat bread', 'brown bread'] });
f('bread_multigrain', 168013, 'Tam tahıllı ekmek', 'Multigrain bread', 'bread_grains', { aliases: ['çok tahıllı ekmek', 'multi-grain bread'] });
f('bread_rye', 172684, 'Çavdar ekmeği', 'Rye bread', 'bread_grains', { aliases: ['rye bread'] });
f('toast_white', 174925, 'Kızarmış ekmek', 'Toast', 'bread_grains', { aliases: ['kızarmış beyaz ekmek', 'toast bread'], skip: ['su bardağı'] });
f('pita', 2707616, 'Pide ekmeği / lavaş', 'Pita bread', 'bread_grains', { aliases: ['pita', 'lavaş', 'pide ekmeği', 'flatbread'], skip: ['porsiyon'] });
f('tortilla', 2707824, 'Tortilla (dürüm lavaşı)', 'Flour tortilla', 'bread_grains', { aliases: ['dürüm', 'wrap', 'tortilla'] });
f('bagel', 2707684, 'Bagel', 'Bagel', 'bread_grains', {});
f('croissant', 2707678, 'Kruvasan', 'Croissant', 'bread_grains', { aliases: ['croissant'] });
f('crackers', 2708132, 'Kraker', 'Crackers', 'bread_grains', { aliases: ['crackers', 'tuzlu kraker'] });
f('oats', 173904, 'Yulaf ezmesi', 'Rolled oats', 'bread_grains', { aliases: ['yulaf', 'oats', 'oatmeal', 'porridge oats'] });
f('granola', 2708461, 'Granola', 'Granola', 'bread_grains', {});
f('corn_flakes', 2708453, 'Mısır gevreği', 'Corn flakes', 'bread_grains', { aliases: ['cornflakes', 'kahvaltılık gevrek'] });
f('rice_white', 168878, 'Pirinç (haşlanmış)', 'White rice, cooked', 'bread_grains', { aliases: ['pirinç', 'beyaz pirinç', 'haşlanmış pirinç', 'rice', 'boiled rice'] });
f('rice_brown', 169704, 'Esmer pirinç (haşlanmış)', 'Brown rice, cooked', 'bread_grains', { aliases: ['esmer pirinç', 'brown rice'] });
f('bulgur', 170287, 'Bulgur (haşlanmış)', 'Bulgur, cooked', 'bread_grains', { aliases: ['haşlanmış bulgur', 'bulgur wheat'] });
f('couscous', 169700, 'Kuskus', 'Couscous', 'bread_grains', { aliases: ['couscous'] });
f('quinoa', 168917, 'Kinoa', 'Quinoa, cooked', 'bread_grains', { aliases: ['quinoa'] });
f('pasta', 169737, 'Makarna (haşlanmış)', 'Pasta, cooked', 'bread_grains', { aliases: ['makarna', 'spagetti', 'penne', 'pasta', 'spaghetti', 'noodles'] });
f('egg_noodles', 169732, 'Yumurtalı erişte (haşlanmış)', 'Egg noodles, cooked', 'bread_grains', { aliases: ['erişte', 'egg noodles'] });
f('potato_boiled', 170438, 'Haşlanmış patates', 'Boiled potato', 'vegetables', { aliases: ['patates', 'potato', 'boiled potatoes'] });
f('french_fries', 2709456, 'Patates kızartması', 'French fries', 'vegetables', { aliases: ['kızarmış patates', 'cips patates', 'fries', 'chips'] });
f('sweet_potato', 170134, 'Tatlı patates (fırın)', 'Sweet potato, baked', 'vegetables', { aliases: ['tatlı patates', 'sweet potato'] });

// ---------------------------------------------------------------------------
// Dairy
// ---------------------------------------------------------------------------
f('white_cheese', 173420, 'Beyaz peynir', 'White cheese (feta type)', 'dairy', { approx: 'USDA "Cheese, feta": Turkish beyaz peynir is a brined feta-type cheese; fat varies by brand', aliases: ['peynir', 'tam yağlı beyaz peynir', 'ezine', 'feta', 'feta cheese', 'cheese'], portionsFrom: 2705714 });
f('feta', 173420, 'Feta peyniri', 'Feta cheese', 'dairy', { aliases: ['feta'], portionsFrom: 2705714 });
f('cheddar', 328637, 'Çedar peyniri', 'Cheddar cheese', 'dairy', { aliases: ['cheddar', 'çedar'], portionsFrom: 173414 });
f('mozzarella', 170845, 'Mozzarella', 'Mozzarella cheese', 'dairy', { aliases: ['mozarella', 'mozzarella cheese'] });
f('cream_cheese', 173418, 'Krem peynir', 'Cream cheese', 'dairy', { aliases: ['labne', 'cream cheese', 'sürülebilir peynir'], approx: 'USDA "Cheese, cream"; labne brands differ' });
f('parmesan', 170848, 'Parmesan', 'Parmesan cheese', 'dairy', { aliases: ['parmesan', 'parmesan peyniri'] });
f('cottage_cheese', 172179, 'Süzme peynir (cottage)', 'Cottage cheese', 'dairy', { aliases: ['cottage', 'cottage peyniri', 'cottage cheese'] });
f('ricotta', 170851, 'Ricotta', 'Ricotta cheese', 'dairy', { aliases: ['ricotta'] });
f('provolone', 170850, 'Provolone', 'Provolone cheese', 'dairy', {});
f('yogurt', 171284, 'Yoğurt (tam yağlı)', 'Yogurt, plain, whole milk', 'dairy', { aliases: ['yoğurt', 'tam yağlı yoğurt', 'ev yoğurdu', 'yogurt', 'yoghurt'] });
f('greek_yogurt', 2259794, 'Süzme yoğurt', 'Greek yogurt', 'dairy', { aliases: ['süzme', 'greek yogurt', 'strained yogurt'], portionsFrom: 171304 });
f('greek_yogurt_nonfat', 330137, 'Süzme yoğurt (yağsız)', 'Greek yogurt, nonfat', 'dairy', { aliases: ['yağsız yoğurt', 'light yoğurt', 'nonfat greek yogurt'], portionsFrom: 170903 });
f('milk_whole', 171265, 'Süt (tam yağlı)', 'Whole milk', 'dairy', { aliases: ['süt', 'tam yağlı süt', 'milk', 'whole milk'], liquid: true });
f('milk_2', 321359, 'Süt (yarım yağlı)', 'Milk, 2% fat', 'dairy', { aliases: ['yarım yağlı süt', 'reduced fat milk', 'semi-skimmed milk'], liquid: true, portionsFrom: 171267 });
f('milk_1', 322228, 'Süt (az yağlı)', 'Milk, 1% fat', 'dairy', { aliases: ['az yağlı süt', 'light süt', 'low fat milk'], liquid: true, portionsFrom: 170872 });
f('kefir', 2705394, 'Kefir', 'Kefir', 'dairy', { liquid: true });
f('buttermilk', 2705393, 'Yayık ayranı (buttermilk)', 'Buttermilk', 'dairy', { aliases: ['buttermilk'], liquid: true });
f('ice_cream_vanilla', 167575, 'Dondurma (vanilyalı)', 'Vanilla ice cream', 'sweets_snacks', { aliases: ['dondurma', 'ice cream'] });
f('ice_cream_chocolate', 2705632, 'Dondurma (çikolatalı)', 'Chocolate ice cream', 'sweets_snacks', { aliases: ['çikolatalı dondurma'] });

// ---------------------------------------------------------------------------
// Fats, spreads, sauces
// ---------------------------------------------------------------------------
f('butter', 173410, 'Tereyağı', 'Butter', 'fats_sauces', { aliases: ['tereyağ', 'butter'], pick: /pat/ });
f('olive_oil', 171413, 'Zeytinyağı', 'Olive oil', 'fats_sauces', { aliases: ['zeytin yağı', 'olive oil'] });
f('sunflower_oil', 171025, 'Ayçiçek yağı', 'Sunflower oil', 'fats_sauces', { aliases: ['ayçiçeği yağı', 'sıvı yağ', 'sunflower oil', 'vegetable oil'], portionsFrom: 171413 });
f('margarine', 2710158, 'Margarin', 'Margarine', 'fats_sauces', { aliases: ['margarine'] });
f('mayonnaise', 2710204, 'Mayonez', 'Mayonnaise', 'fats_sauces', { aliases: ['mayo', 'mayonnaise'] });
f('ketchup', 2709733, 'Ketçap', 'Ketchup', 'fats_sauces', { aliases: ['ketchup'] });
f('mustard', 2710085, 'Hardal', 'Mustard', 'fats_sauces', { aliases: ['mustard'] });
f('soy_sauce', 2707442, 'Soya sosu', 'Soy sauce', 'fats_sauces', { aliases: ['soy sauce'] });
f('tahini', 170189, 'Tahin', 'Tahini', 'fats_sauces', { aliases: ['tahini', 'sesame paste'] });
f('peanut_butter', 172470, 'Fıstık ezmesi', 'Peanut butter', 'fats_sauces', { aliases: ['peanut butter'] });
f('honey', 169640, 'Bal', 'Honey', 'fats_sauces', { aliases: ['süzme bal', 'honey'] });
f('jam', 169641, 'Reçel', 'Jam', 'fats_sauces', { aliases: ['marmelat', 'jam', 'preserves'] });
f('molasses', 168820, 'Pekmez', 'Molasses', 'fats_sauces', { approx: 'USDA "Molasses" (sugar cane); Turkish pekmez is made from grapes or carob', aliases: ['üzüm pekmezi', 'molasses'] });
f('hazelnut_spread', 168000, 'Fındık kreması', 'Chocolate hazelnut spread', 'fats_sauces', { aliases: ['kakaolu fındık kreması', 'nutella', 'hazelnut spread'] });
f('sugar', 169655, 'Şeker', 'Sugar', 'fats_sauces', { aliases: ['toz şeker', 'küp şeker', 'sugar'], pick: /cube/ });

// ---------------------------------------------------------------------------
// Meat, poultry, fish
// ---------------------------------------------------------------------------
f('chicken_breast', 171477, 'Tavuk göğsü (ızgara/fırın)', 'Chicken breast, roasted', 'meat_fish', { aliases: ['tavuk göğüs', 'tavuk', 'ızgara tavuk', 'chicken', 'chicken breast', 'grilled chicken'] });
f('chicken_thigh', 172388, 'Tavuk but (fırın)', 'Chicken thigh, roasted', 'meat_fish', { aliases: ['tavuk but', 'pirzola tavuk', 'chicken thigh'] });
f('chicken_drumstick', 172377, 'Tavuk baget (haşlanmış)', 'Chicken drumstick, stewed', 'meat_fish', { aliases: ['baget', 'drumstick'] });
f('chicken_wings', 2706078, 'Tavuk kanat', 'Chicken wings', 'meat_fish', { aliases: ['kanat', 'chicken wings'] });
f('chicken_nuggets', 2706092, 'Tavuk nugget', 'Chicken nuggets', 'meat_fish', { aliases: ['nugget', 'chicken nuggets'] });
f('turkey_breast', 171496, 'Hindi göğsü', 'Turkey breast, roasted', 'meat_fish', { aliases: ['hindi', 'turkey'] });
f('beef_ground_20', 171797, 'Kıyma (pişmiş, %20 yağlı)', 'Ground beef 80/20, cooked', 'meat_fish', { aliases: ['kıyma', 'dana kıyma', 'ground beef', 'minced beef'] });
f('beef_ground_10', 174031, 'Yağsız kıyma (pişmiş, %10 yağlı)', 'Lean ground beef 90/10, cooked', 'meat_fish', { aliases: ['az yağlı kıyma', 'lean mince'] });
f('beef_steak', 173118, 'Dana biftek (ızgara)', 'Beef steak, grilled', 'meat_fish', { aliases: ['biftek', 'bonfile', 'antrikot', 'et', 'kırmızı et', 'steak', 'beef'] });
f('beef_stew_meat', 2705849, 'Kuşbaşı dana eti (pişmiş)', 'Beef stew meat, cooked', 'meat_fish', { aliases: ['kuşbaşı', 'kuşbaşı et', 'stew meat'] });
f('lamb_ground', 172544, 'Kuzu kıyma (pişmiş)', 'Ground lamb, cooked', 'meat_fish', { aliases: ['kuzu kıyma', 'ground lamb'] });
f('lamb_cubes', 172510, 'Kuzu kuşbaşı (ızgara)', 'Lamb cubes, grilled', 'meat_fish', { aliases: ['kuzu eti', 'kuzu', 'lamb'] });
f('liver', 168627, 'Ciğer (tavada)', 'Beef liver, pan-fried', 'meat_fish', { aliases: ['ciğer', 'dana ciğer', 'arnavut ciğeri', 'liver'], approx: 'USDA "Beef liver, pan-fried"; Arnavut ciğeri also includes flour and frying oil' });
f('salami', 2706195, 'Salam', 'Salami', 'meat_fish', { aliases: ['salami'] });
f('frankfurter', 174614, 'Sosis', 'Frankfurter (hot dog sausage)', 'meat_fish', { aliases: ['sosis', 'frankfurter', 'hot dog sausage'] });
f('turkey_sausage', 2706200, 'Hindi / tavuk sosis', 'Turkey or chicken sausage', 'meat_fish', { aliases: ['hindi sosis', 'tavuk sosis'] });
f('ham', 173864, 'Jambon', 'Ham, sliced', 'meat_fish', { aliases: ['ham'] });
f('pastrami', 170204, 'Pastırma', 'Pastrami', 'meat_fish', { approx: 'USDA "Beef, cured, pastrami"; Turkish pastırma is air-dried with çemen, so it is drier', aliases: ['pastrami'] });
f('salmon', 175168, 'Somon (pişmiş)', 'Salmon, cooked', 'meat_fish', { aliases: ['somon', 'somon balığı', 'salmon'] });
f('tuna_canned', 334194, 'Ton balığı (suda, konserve)', 'Tuna, canned in water', 'meat_fish', { aliases: ['ton balığı', 'ton', 'tuna'], portionsFrom: 171986 });
f('sea_bass', 173694, 'Levrek (pişmiş)', 'Sea bass, cooked', 'meat_fish', { aliases: ['levrek', 'çipura', 'sea bass'], approx: 'USDA "Fish, sea bass, mixed species"; used for levrek and çipura' });
f('anchovy', 174182, 'Hamsi (çiğ)', 'Anchovy, raw', 'meat_fish', { aliases: ['hamsi', 'anchovy'] });
f('mackerel', 175120, 'Uskumru (pişmiş)', 'Mackerel, cooked', 'meat_fish', { aliases: ['uskumru', 'kolyoz', 'mackerel'] });
f('trout', 173718, 'Alabalık (pişmiş)', 'Rainbow trout, cooked', 'meat_fish', { aliases: ['alabalık', 'trout'] });
f('shrimp', 175180, 'Karides (pişmiş)', 'Shrimp, cooked', 'meat_fish', { aliases: ['karides', 'shrimp', 'prawns'] });
f('fish_fried', 2706244, 'Balık kızartması', 'Fried fish', 'meat_fish', { approx: 'USDA "Fish, cod, fried" (battered); Turkish pan-fried fish varies', aliases: ['kızarmış balık', 'balık tava', 'fried fish', 'fish and chips fish'] });
f('meatballs_plain', 171638, 'Köfte (hazır, dondurulmuş)', 'Meatballs, frozen, Italian style', 'meat_fish', { aliases: ['hazır köfte', 'meatballs'] });
f('tofu', 172475, 'Tofu', 'Tofu, firm', 'legumes', {});

// ---------------------------------------------------------------------------
// Legumes
// ---------------------------------------------------------------------------
f('lentils', 172421, 'Mercimek (haşlanmış)', 'Lentils, boiled', 'legumes', { aliases: ['haşlanmış mercimek', 'yeşil mercimek', 'lentils'] });
f('chickpeas', 173757, 'Nohut (haşlanmış)', 'Chickpeas, boiled', 'legumes', { aliases: ['nohut', 'haşlanmış nohut', 'chickpeas', 'garbanzo'] });
f('white_beans', 175203, 'Kuru fasulye (haşlanmış, sade)', 'White beans, boiled', 'legumes', { aliases: ['haşlanmış kuru fasulye', 'white beans'] });
f('kidney_beans', 175194, 'Barbunya / kırmızı fasulye (haşlanmış)', 'Kidney beans, boiled', 'legumes', { aliases: ['barbunya', 'kırmızı fasulye', 'kidney beans'] });
f('hummus', 172454, 'Humus', 'Hummus', 'legumes', { aliases: ['humus', 'hummus'] });
f('falafel', 2707408, 'Falafel', 'Falafel', 'world_dishes', {});

// ---------------------------------------------------------------------------
// Vegetables
// ---------------------------------------------------------------------------
f('tomato', 170457, 'Domates', 'Tomato', 'vegetables', { aliases: ['domates', 'tomato', 'tomatoes'] });
f('cucumber', 168409, 'Salatalık', 'Cucumber', 'vegetables', { aliases: ['salatalık', 'hıyar', 'cucumber'] });
f('green_pepper', 170427, 'Yeşil biber (dolmalık/çarliston)', 'Green bell pepper', 'vegetables', { aliases: ['biber', 'dolmalık biber', 'çarliston biber', 'green pepper', 'bell pepper'] });
f('chili_pepper', 170497, 'Sivri biber / acı biber', 'Green chili pepper', 'vegetables', { aliases: ['sivri biber', 'acı biber', 'chili pepper'] });
f('onion', 170000, 'Soğan', 'Onion', 'vegetables', { aliases: ['kuru soğan', 'onion'] });
f('garlic', 169230, 'Sarımsak', 'Garlic', 'vegetables', { aliases: ['garlic'] });
f('carrot', 170393, 'Havuç', 'Carrot', 'vegetables', { aliases: ['carrot'] });
f('lettuce', 169247, 'Marul', 'Romaine lettuce', 'vegetables', { aliases: ['göbek marul', 'lettuce', 'romaine'] });
f('spinach_raw', 168462, 'Ispanak (çiğ)', 'Spinach, raw', 'vegetables', { aliases: ['ıspanak', 'spinach'] });
f('spinach_cooked', 168463, 'Ispanak (haşlanmış)', 'Spinach, boiled', 'vegetables', { aliases: ['haşlanmış ıspanak'] });
f('broccoli', 169967, 'Brokoli (haşlanmış)', 'Broccoli, boiled', 'vegetables', { aliases: ['brokoli', 'broccoli'] });
f('cauliflower', 170397, 'Karnabahar (haşlanmış)', 'Cauliflower, boiled', 'vegetables', { aliases: ['karnabahar', 'cauliflower'] });
f('eggplant', 169229, 'Patlıcan (haşlanmış)', 'Eggplant, boiled', 'vegetables', { aliases: ['patlıcan', 'eggplant', 'aubergine'] });
f('zucchini', 169292, 'Kabak (haşlanmış)', 'Zucchini, boiled', 'vegetables', { aliases: ['kabak', 'sakız kabağı', 'zucchini', 'courgette'] });
f('cabbage', 169975, 'Lahana', 'Cabbage', 'vegetables', { aliases: ['beyaz lahana', 'cabbage'] });
f('parsley', 170416, 'Maydanoz', 'Parsley', 'vegetables', { aliases: ['parsley'] });
f('dill', 172233, 'Dereotu', 'Dill', 'vegetables', { aliases: ['dill'] });
f('arugula', 169387, 'Roka', 'Arugula', 'vegetables', { aliases: ['rocket', 'arugula'] });
f('mushrooms', 169251, 'Mantar', 'Mushrooms', 'vegetables', { aliases: ['kültür mantarı', 'mushroom', 'mushrooms'] });
f('corn', 169999, 'Mısır (haşlanmış)', 'Sweet corn, boiled', 'vegetables', { aliases: ['mısır', 'corn', 'sweet corn'] });
f('peas', 170420, 'Bezelye (haşlanmış)', 'Green peas, boiled', 'vegetables', { aliases: ['bezelye', 'peas'] });
f('green_beans', 169141, 'Taze fasulye (haşlanmış)', 'Green beans, boiled', 'vegetables', { aliases: ['haşlanmış taze fasulye', 'green beans'] });
f('okra', 169260, 'Bamya (çiğ)', 'Okra, raw', 'vegetables', { aliases: ['bamya', 'okra'] });
f('leek', 168426, 'Pırasa (haşlanmış)', 'Leeks, boiled', 'vegetables', { aliases: ['pırasa', 'leek'] });
f('celery', 169988, 'Kereviz sapı', 'Celery', 'vegetables', { aliases: ['kereviz', 'celery'] });
f('beet', 169145, 'Pancar', 'Beets', 'vegetables', { aliases: ['kırmızı pancar', 'beet', 'beetroot'] });
f('radish', 169276, 'Turp', 'Radishes', 'vegetables', { aliases: ['radish'] });
f('pumpkin', 168448, 'Bal kabağı', 'Pumpkin', 'vegetables', { aliases: ['balkabağı', 'pumpkin'] });
f('artichoke', 169205, 'Enginar', 'Artichoke', 'vegetables', { aliases: ['artichoke'] });
f('avocado', 171705, 'Avokado', 'Avocado', 'fruit', { aliases: ['avocado'] });
f('olives_green', 169096, 'Yeşil zeytin', 'Green olives', 'breakfast', { aliases: ['zeytin', 'yeşil zeytin', 'olives', 'green olives'] });
f('olives_black', 169094, 'Siyah zeytin', 'Black olives', 'breakfast', { aliases: ['siyah zeytin', 'black olives'], pick: /large/ });

// ---------------------------------------------------------------------------
// Fruit
// ---------------------------------------------------------------------------
f('apple', 171688, 'Elma', 'Apple', 'fruit', { aliases: ['apple'] });
f('banana', 173944, 'Muz', 'Banana', 'fruit', { aliases: ['banana'] });
f('orange', 169097, 'Portakal', 'Orange', 'fruit', { aliases: ['orange'] });
f('tangerine', 169105, 'Mandalina', 'Tangerine', 'fruit', { aliases: ['mandarin', 'tangerine'] });
f('pear', 169118, 'Armut', 'Pear', 'fruit', { aliases: ['pear'] });
f('grapes', 174683, 'Üzüm', 'Grapes', 'fruit', { aliases: ['grapes'] });
f('strawberries', 167762, 'Çilek', 'Strawberries', 'fruit', { aliases: ['strawberry', 'strawberries'] });
f('watermelon', 167765, 'Karpuz', 'Watermelon', 'fruit', { aliases: ['watermelon'] });
f('melon', 169092, 'Kavun', 'Melon', 'fruit', { aliases: ['melon', 'cantaloupe'], approx: 'USDA "Melons, cantaloupe"; Turkish kavun varieties differ' });
f('peach', 169928, 'Şeftali', 'Peach', 'fruit', { aliases: ['peach'] });
f('apricot', 171697, 'Kayısı', 'Apricot', 'fruit', { aliases: ['apricot'] });
f('dried_apricot', 173941, 'Kuru kayısı', 'Dried apricots', 'fruit', { aliases: ['dried apricot'] });
f('plum', 169949, 'Erik', 'Plum', 'fruit', { aliases: ['plum'] });
f('cherries', 171719, 'Kiraz', 'Sweet cherries', 'fruit', { aliases: ['cherry', 'cherries'] });
f('figs', 173021, 'İncir', 'Figs', 'fruit', { aliases: ['taze incir', 'fig'] });
f('dried_figs', 326905, 'Kuru incir', 'Dried figs', 'fruit', { aliases: ['dried figs'], portionsFrom: 174665 });
f('dates', 168191, 'Hurma', 'Medjool dates', 'fruit', { aliases: ['date', 'dates'] });
f('raisins', 168165, 'Kuru üzüm', 'Raisins', 'fruit', { aliases: ['raisins'], skip: ['adet'] });
f('pomegranate', 169134, 'Nar', 'Pomegranate', 'fruit', { aliases: ['pomegranate'] });
f('kiwi', 168153, 'Kivi', 'Kiwi', 'fruit', { aliases: ['kiwi'] });
f('pineapple', 169124, 'Ananas', 'Pineapple', 'fruit', { aliases: ['pineapple'] });
f('mango', 169910, 'Mango', 'Mango', 'fruit', {});
f('lemon_juice', 167747, 'Limon suyu', 'Lemon juice', 'fruit', { aliases: ['limon', 'lemon juice'], liquid: true, skip: ['adet'] });

// ---------------------------------------------------------------------------
// Nuts and seeds
// ---------------------------------------------------------------------------
f('walnuts', 170187, 'Ceviz', 'Walnuts', 'nuts_seeds', { aliases: ['ceviz içi', 'walnut', 'walnuts'] });
f('almonds', 170567, 'Badem', 'Almonds', 'nuts_seeds', { aliases: ['almond', 'almonds'] });
f('hazelnuts', 170581, 'Fındık', 'Hazelnuts', 'nuts_seeds', { aliases: ['fındık içi', 'hazelnut', 'hazelnuts'] });
f('pistachios', 170185, 'Antep fıstığı', 'Pistachios', 'nuts_seeds', { aliases: ['fıstık', 'antep fıstığı', 'pistachio'] });
f('peanuts', 173806, 'Yer fıstığı', 'Peanuts', 'nuts_seeds', { aliases: ['yerfıstığı', 'peanut', 'peanuts'] });
f('sunflower_seeds', 170562, 'Ay çekirdeği (iç)', 'Sunflower seeds', 'nuts_seeds', { aliases: ['çekirdek', 'ayçekirdeği', 'sunflower seeds'] });
f('pumpkin_seeds', 170556, 'Kabak çekirdeği (iç)', 'Pumpkin seeds', 'nuts_seeds', { aliases: ['kabak çekirdeği', 'pumpkin seeds'] });

// ---------------------------------------------------------------------------
// Drinks
// ---------------------------------------------------------------------------
f('water', 173647, 'Su', 'Water', 'drinks', { aliases: ['içme suyu', 'water'], liquid: true });
f('tea', 173227, 'Çay (şekersiz)', 'Black tea', 'drinks', { aliases: ['çay', 'demlik çay', 'siyah çay', 'tea'], liquid: true });
f('coffee', 171890, 'Filtre kahve', 'Brewed coffee', 'drinks', { aliases: ['kahve', 'filtre kahve', 'americano', 'coffee'], liquid: true });
f('turkish_coffee', 2710377, 'Türk kahvesi', 'Turkish coffee', 'drinks', { aliases: ['türk kahvesi', 'turkish coffee'], liquid: true, skip: ['porsiyon', 'su bardağı'] });
f('latte', 2710386, 'Latte', 'Caffe latte', 'drinks', { aliases: ['latte', 'sütlü kahve'], liquid: true });
f('cappuccino', 2710472, 'Kapuçino', 'Cappuccino', 'drinks', { aliases: ['cappuccino'], liquid: true });
f('hot_chocolate', 2705472, 'Sıcak çikolata', 'Hot chocolate', 'drinks', { aliases: ['hot chocolate', 'cocoa'], liquid: true });
f('cola', 174852, 'Kola', 'Cola', 'drinks', { aliases: ['gazlı içecek', 'cola', 'soda'], liquid: true });
f('orange_juice', 169098, 'Portakal suyu (taze)', 'Orange juice, fresh', 'drinks', { aliases: ['portakal suyu', 'orange juice'], liquid: true, skip: ['adet'] });
f('apple_juice', 173933, 'Elma suyu', 'Apple juice', 'drinks', { aliases: ['apple juice'], liquid: true });
f('lemonade', 2710570, 'Limonata', 'Lemonade', 'drinks', { aliases: ['lemonade'], liquid: true });
f('smoothie', 2705513, 'Meyveli smoothie', 'Fruit smoothie', 'drinks', { aliases: ['smoothie'], liquid: true });
f('energy_drink', 2710756, 'Enerji içeceği', 'Energy drink', 'drinks', { aliases: ['energy drink'], liquid: true });
f('beer', 2710616, 'Bira', 'Beer', 'drinks', { aliases: ['beer'], liquid: true });
f('red_wine', 2710688, 'Kırmızı şarap', 'Red wine', 'drinks', { aliases: ['şarap', 'wine', 'red wine'], liquid: true });

// ---------------------------------------------------------------------------
// Sweets and snacks
// ---------------------------------------------------------------------------
f('dark_chocolate', 170273, 'Bitter çikolata (%70-85)', 'Dark chocolate 70-85%', 'sweets_snacks', { aliases: ['bitter çikolata', 'çikolata', 'dark chocolate', 'chocolate'] });
f('chocolate_cake', 2707868, 'Çikolatalı kek', 'Chocolate cake', 'sweets_snacks', { aliases: ['kek', 'çikolatalı pasta', 'chocolate cake', 'cake'] });
f('sponge_cake', 172706, 'Pandispanya / sade kek', 'Sponge cake', 'sweets_snacks', { aliases: ['sade kek', 'pandispanya', 'sponge cake'] });
f('cheesecake', 2707861, 'Cheesecake', 'Cheesecake', 'sweets_snacks', {});
f('brownie', 2707904, 'Brownie', 'Brownie', 'sweets_snacks', {});
f('cookie', 2707899, 'Kurabiye', 'Cookie', 'sweets_snacks', { aliases: ['kurabiye', 'cookie', 'cookies'] });
f('biscuit_plain', 2707971, 'Bisküvi (sade / Marie)', 'Plain biscuit (Marie)', 'sweets_snacks', { aliases: ['bisküvi', 'biscuit'] });
f('doughnut', 2708062, 'Donut', 'Doughnut', 'sweets_snacks', { aliases: ['donut', 'doughnut'] });
f('muffin', 2707829, 'Muffin', 'Muffin', 'sweets_snacks', {});
f('pudding_chocolate', 2705679, 'Puding (çikolatalı)', 'Chocolate pudding', 'sweets_snacks', { aliases: ['puding', 'pudding'] });
f('potato_chips', 169677, 'Cips', 'Potato chips', 'sweets_snacks', { aliases: ['patates cipsi', 'crisps', 'potato chips'] });
f('popcorn', 167959, 'Patlamış mısır', 'Popcorn, air-popped', 'sweets_snacks', { aliases: ['popcorn'] });
f('pretzel', 2708247, 'Kraker çubuk (pretzel)', 'Pretzels', 'sweets_snacks', { aliases: ['pretzel', 'çubuk kraker'] });

// ---------------------------------------------------------------------------
// Turkish dishes: close USDA stand-ins (approximations, flagged for review)
// ---------------------------------------------------------------------------
f('lentil_soup', 2707462, 'Mercimek çorbası', 'Lentil soup', 'soups', { approx: 'USDA FNDDS "Soup, lentil", not a Turkish recipe', aliases: ['mercimek', 'kırmızı mercimek çorbası', 'lentil soup'] });
f('tomato_soup', 2709757, 'Domates çorbası', 'Tomato soup', 'soups', { approx: 'USDA FNDDS "Soup, tomato"', aliases: ['tomato soup'] });
f('chicken_soup', 2709149, 'Şehriyeli tavuk çorbası', 'Chicken noodle soup', 'soups', { approx: 'USDA FNDDS "Soup, chicken noodle"', aliases: ['tavuk çorbası', 'şehriye çorbası', 'chicken soup', 'chicken noodle soup'] });
f('vegetable_soup', 2710113, 'Sebze çorbası', 'Vegetable soup', 'soups', { approx: 'USDA FNDDS "Soup, vegetable"', aliases: ['vegetable soup'] });
f('mushroom_soup', 2710107, 'Kremalı mantar çorbası', 'Cream of mushroom soup', 'soups', { approx: 'USDA FNDDS "Soup, cream of mushroom"', aliases: ['mantar çorbası', 'mushroom soup'] });
f('potato_soup', 2709556, 'Patates çorbası', 'Potato soup', 'soups', { approx: 'USDA FNDDS "Soup, potato"', aliases: ['potato soup'] });
f('pumpkin_soup', 2709718, 'Bal kabağı çorbası', 'Pumpkin soup', 'soups', { approx: 'USDA FNDDS "Soup, pumpkin"', aliases: ['pumpkin soup'] });
f('rice_pilaf', 2709077, 'Pirinç pilavı', 'Rice pilaf', 'turkish_dishes', { approx: 'USDA FNDDS "Rice pilaf"', aliases: ['pilav', 'tereyağlı pilav', 'rice pilaf', 'pilaf'] });
f('bulgur_pilaf', 2708439, 'Bulgur pilavı', 'Bulgur pilaf', 'turkish_dishes', { approx: 'USDA FNDDS "Bulgur, cooked, fat added"', aliases: ['bulgur pilaf'] });
f('stuffed_grape_leaves', 2709064, 'Zeytinyağlı yaprak sarma', 'Stuffed grape leaves (with rice)', 'turkish_dishes', { approx: 'USDA FNDDS "Grape leaves, stuffed with rice"', aliases: ['yaprak sarma', 'sarma', 'yaprak dolma', 'dolma', 'stuffed vine leaves'] });
f('stuffed_peppers_rice', 2709074, 'Zeytinyağlı biber dolması', 'Stuffed peppers with rice', 'turkish_dishes', { approx: 'USDA FNDDS "Stuffed pepper, with rice, meatless"', aliases: ['biber dolması', 'stuffed peppers'] });
f('stuffed_peppers_meat', 2709073, 'Etli biber dolması', 'Stuffed peppers with rice and meat', 'turkish_dishes', { approx: 'USDA FNDDS "Stuffed pepper, with rice and meat"', aliases: ['etli dolma'] });
f('cabbage_rolls', 2706620, 'Etli lahana sarması', 'Cabbage rolls with meat and rice', 'turkish_dishes', { approx: 'USDA FNDDS "Stuffed cabbage rolls with beef and rice"', aliases: ['lahana sarması', 'lahana dolması', 'cabbage rolls'] });
f('cacik', 2705448, 'Cacık', 'Cacik (yogurt-cucumber dip)', 'turkish_dishes', { approx: 'USDA FNDDS "Tzatziki dip"; cacık is usually thinner (with water)', aliases: ['tzatziki'] });
f('baba_ganoush', 2710049, 'Patlıcan salatası / babagannuş', 'Eggplant dip (baba ganoush)', 'turkish_dishes', { approx: 'USDA FNDDS "Eggplant dip"', aliases: ['babagannuş', 'baba ganuş', 'patlıcan salatası', 'baba ganoush'] });
f('baklava', 2708044, 'Baklava', 'Baklava', 'sweets_snacks', { approx: 'USDA FNDDS "Baklava"; Turkish baklava syrup and nuts vary', aliases: ['fıstıklı baklava', 'cevizli baklava'] });
f('rice_pudding', 2705685, 'Sütlaç', 'Rice pudding', 'sweets_snacks', { approx: 'USDA FNDDS "Pudding, rice"', aliases: ['fırın sütlaç', 'rice pudding'] });
f('spinach_borek', 2708729, 'Ispanaklı börek', 'Spinach pie (börek)', 'turkish_dishes', { approx: 'USDA FNDDS "Spanakopita" (spinach and feta in phyllo)', aliases: ['börek', 'ıspanaklı börek', 'spanakopita'] });
f('lamb_shish', 2706780, 'Kuzu şiş', 'Lamb shish kebab', 'turkish_dishes', { approx: 'USDA FNDDS "Lamb shish kabob with vegetables"', aliases: ['şiş kebap', 'şiş', 'shish kebab'] });
f('chicken_shish', 2706783, 'Tavuk şiş', 'Chicken shish kebab', 'turkish_dishes', { approx: 'USDA FNDDS "Chicken or turkey shish kabob with vegetables"', aliases: ['chicken kebab', 'chicken shish'] });
f('doner_sandwich', 2706962, 'Döner (ekmek arası)', 'Döner / gyro sandwich', 'turkish_dishes', { approx: 'USDA FNDDS "Gyro sandwich"', aliases: ['döner', 'döner ekmek', 'dürüm döner', 'gyro', 'doner'] });
f('tabbouleh', 2709131, 'Tabule', 'Tabbouleh', 'world_dishes', { approx: 'USDA FNDDS "Tabbouleh"; close to kısır but kısır uses more bulgur and pepper paste', aliases: ['tabbouleh'] });
f('beef_stew', 2706592, 'Etli sebze yemeği / et sote', 'Beef stew', 'turkish_dishes', { approx: 'USDA FNDDS "Stew, beef"', aliases: ['et sote', 'etli türlü', 'beef stew', 'tas kebabı'] });
f('chicken_stew', 2706678, 'Tavuk sote', 'Chicken stew', 'turkish_dishes', { approx: 'USDA FNDDS "Stew, chicken"', aliases: ['tavuk yahni', 'chicken stew'] });
f('green_beans_oil', 2709859, 'Zeytinyağlı taze fasulye', 'Green beans cooked with oil', 'turkish_dishes', { approx: 'USDA FNDDS "Green beans, fresh, cooked with oil"', aliases: ['taze fasulye'] });
f('okra_cooked', 2709947, 'Zeytinyağlı bamya', 'Okra cooked with oil', 'turkish_dishes', { approx: 'USDA FNDDS "Okra, fresh, cooked, fat added"', aliases: ['bamya yemeği'] });
f('liver_onions', 2706876, 'Ciğer soğan', 'Liver and onions', 'turkish_dishes', { approx: 'USDA FNDDS "Liver, beef or calves, and onions"', aliases: ['liver and onions'] });
f('omelette_cheese', 2707208, 'Peynirli omlet', 'Cheese omelette', 'eggs', { aliases: ['kaşarlı omlet', 'cheese omelet'] });

// ---------------------------------------------------------------------------
// World dishes (USDA FNDDS)
// ---------------------------------------------------------------------------
f('pizza', 2708622, 'Pizza (peynirli, ince hamur)', 'Cheese pizza, thin crust', 'world_dishes', { aliases: ['pizza', 'peynirli pizza', 'margarita pizza'] });
f('hamburger', 2706920, 'Hamburger', 'Hamburger', 'world_dishes', { aliases: ['burger'] });
f('cheeseburger', 2706888, 'Cheeseburger', 'Cheeseburger', 'world_dishes', {});
f('hot_dog', 2706166, 'Sosisli sandviç', 'Hot dog', 'world_dishes', { aliases: ['sosisli', 'hot dog'] });
f('grilled_cheese', 2705801, 'Kaşarlı tost', 'Grilled cheese sandwich', 'world_dishes', { approx: 'USDA FNDDS "Grilled cheese sandwich"; made with American cheese, not kaşar', aliases: ['tost', 'kaşarlı tost', 'grilled cheese', 'toast sandwich'] });
f('chicken_sandwich', 2707000, 'Tavuk sandviç', 'Chicken sandwich', 'world_dishes', { aliases: ['chicken sandwich'] });
f('tuna_salad', 2706828, 'Ton balıklı salata (mayonezli)', 'Tuna salad with mayonnaise', 'world_dishes', { aliases: ['tuna salad'] });
f('french_toast', 2708331, 'Yumurtalı ekmek', 'French toast', 'breakfast', { aliases: ['french toast'] });
f('pancakes', 2708304, 'Pankek', 'Pancakes', 'breakfast', { aliases: ['pancake', 'pancakes'] });
f('waffle', 2708325, 'Waffle', 'Waffle', 'sweets_snacks', {});
f('sushi', 2708959, 'Suşi', 'Sushi', 'world_dishes', { aliases: ['sushi'] });
f('fried_rice', 2708952, 'Kızarmış pilav (Çin usulü)', 'Fried rice', 'world_dishes', { aliases: ['fried rice'] });
f('lo_mein', 2708798, 'Lo mein (Çin eriştesi)', 'Lo mein', 'world_dishes', { aliases: ['noodle', 'çin eriştesi'] });
f('egg_roll', 2708700, 'Çin böreği (egg roll)', 'Egg roll', 'world_dishes', { aliases: ['spring roll', 'egg roll', 'çin böreği'] });
f('dumplings', 2708708, 'Mantı tipi hamur (buharda, Uzak Doğu)', 'Dumplings, steamed', 'world_dishes', { aliases: ['gyoza', 'wonton', 'dumplings', 'pot sticker'] });
f('pad_thai', 2708804, 'Pad Thai', 'Pad Thai', 'world_dishes', {});
f('ramen', 2709153, 'Ramen', 'Ramen', 'world_dishes', {});
f('pho', 2707124, 'Pho', 'Pho', 'world_dishes', {});
f('beef_curry', 2706388, 'Etli köri', 'Beef curry', 'world_dishes', { aliases: ['köri', 'curry'] });
f('dal', 2707427, 'Dal (Hint mercimek yemeği)', 'Dal', 'world_dishes', { aliases: ['dahl', 'dal'] });
f('naan', 2707613, 'Naan ekmeği', 'Naan', 'bread_grains', { aliases: ['naan'] });
f('burrito', 2708534, 'Burrito', 'Burrito', 'world_dishes', {});
f('taco', 2708514, 'Taco', 'Taco', 'world_dishes', {});
f('quesadilla', 2708590, 'Quesadilla', 'Quesadilla', 'world_dishes', {});
f('enchilada', 2708565, 'Enchilada', 'Enchilada', 'world_dishes', {});
f('nachos', 2708576, 'Nachos', 'Nachos', 'world_dishes', {});
f('fajita', 2708604, 'Tavuk fajita', 'Chicken fajita', 'world_dishes', { aliases: ['fajita'] });
f('tamale', 2708570, 'Tamale', 'Tamale', 'world_dishes', {});
f('empanada', 2708709, 'Empanada', 'Empanada', 'world_dishes', {});
f('lasagna', 2708750, 'Lazanya (kıymalı)', 'Lasagna with meat', 'world_dishes', { aliases: ['lazanya', 'lasagna', 'lasagne'] });
f('spaghetti_meat_sauce', 167680, 'Bolonez soslu spagetti', 'Spaghetti with meat sauce', 'world_dishes', { aliases: ['spagetti bolonez', 'bolonez', 'spaghetti bolognese'] });
f('paella', 2706723, 'Paella', 'Paella', 'world_dishes', {});
f('gnocchi', 2708722, 'Gnocchi', 'Potato gnocchi', 'world_dishes', { aliases: ['noki'] });
f('pierogi', 2708720, 'Pierogi', 'Pierogi', 'world_dishes', {});
f('ravioli', 2708767, 'Peynirli ravioli', 'Cheese ravioli', 'world_dishes', { aliases: ['ravioli'] });
f('caesar_salad', 2709591, 'Sezar salata (sossuz)', 'Caesar salad, no dressing', 'world_dishes', { aliases: ['sezar', 'caesar salad'] });
f('greek_salad', 2709830, 'Yunan salatası (sossuz)', 'Greek salad, no dressing', 'world_dishes', { aliases: ['greek salad', 'köy salatası'], approx: 'USDA FNDDS "Greek Salad"; close to köy salatası with feta' });
f('potato_salad', 2709543, 'Patates salatası', 'Potato salad', 'world_dishes', { aliases: ['potato salad'] });
f('coleslaw', 2709815, 'Coleslaw (lahana salatası, mayonezli)', 'Coleslaw', 'world_dishes', { aliases: ['coleslaw'] });
f('quiche', 2708733, 'Kiş', 'Quiche', 'world_dishes', { aliases: ['quiche'] });
f('kimchi', 2710077, 'Kimchi', 'Kimchi', 'world_dishes', {});
f('mac_and_cheese', 2708822, 'Peynirli makarna', 'Macaroni and cheese', 'world_dishes', { aliases: ['mac and cheese', 'macaroni and cheese'] });

// ---------------------------------------------------------------------------
// Turkish dishes with no USDA equivalent: `todo`, no values until a dietitian
// enters them (from TürKomp or a recipe calculation) and verifies them.
// ---------------------------------------------------------------------------
const todo = (key, tr, en, category, aliases = []) => f(key, null, tr, en, category, { aliases });
todo('menemen', 'Menemen', 'Menemen (eggs with tomato and pepper)', 'eggs');
todo('sucuk', 'Sucuk', 'Sucuk (Turkish sausage)', 'meat_fish', ['sucuk']);
todo('sucuklu_yumurta', 'Sucuklu yumurta', 'Eggs with sucuk', 'eggs');
todo('kasar', 'Kaşar peyniri', 'Kashar cheese', 'dairy', ['kaşar', 'taze kaşar', 'eski kaşar']);
todo('lor', 'Lor peyniri', 'Lor (whey cheese)', 'dairy', ['lor']);
todo('tulum', 'Tulum peyniri', 'Tulum cheese', 'dairy');
todo('ayran', 'Ayran', 'Ayran (yogurt drink)', 'drinks', ['ayran', 'yogurt drink']);
todo('salgam', 'Şalgam suyu', 'Şalgam (fermented carrot drink)', 'drinks', ['şalgam']);
todo('boza', 'Boza', 'Boza', 'drinks');
todo('simit', 'Simit', 'Simit (sesame bread ring)', 'bread_grains', ['gevrek']);
todo('pogaca', 'Poğaça', 'Poğaça', 'bread_grains', ['peynirli poğaça']);
todo('acma', 'Açma', 'Açma', 'bread_grains');
todo('gozleme', 'Gözleme', 'Gözleme', 'turkish_dishes');
todo('su_boregi', 'Su böreği', 'Su böreği', 'turkish_dishes');
todo('sigara_boregi', 'Sigara böreği', 'Sigara böreği (fried cheese rolls)', 'turkish_dishes');
todo('lahmacun', 'Lahmacun', 'Lahmacun', 'turkish_dishes');
todo('pide', 'Kıymalı pide', 'Pide with minced meat', 'turkish_dishes', ['pide', 'kaşarlı pide', 'kuşbaşılı pide']);
todo('manti', 'Mantı', 'Mantı (Turkish dumplings)', 'turkish_dishes', ['kayseri mantısı']);
todo('izgara_kofte', 'Izgara köfte', 'Grilled meatballs (köfte)', 'turkish_dishes', ['köfte', 'kasap köfte', 'meatballs']);
todo('icli_kofte', 'İçli köfte', 'İçli köfte', 'turkish_dishes');
todo('cig_kofte', 'Çiğ köfte', 'Çiğ köfte (vegan)', 'turkish_dishes');
todo('mercimek_koftesi', 'Mercimek köftesi', 'Lentil patties', 'turkish_dishes');
todo('adana', 'Adana kebap', 'Adana kebab', 'turkish_dishes', ['adana', 'urfa kebap']);
todo('iskender', 'İskender', 'İskender kebab', 'turkish_dishes', ['iskender kebap']);
todo('tavuk_doner', 'Tavuk döner', 'Chicken döner', 'turkish_dishes');
todo('kuru_fasulye', 'Kuru fasulye (etli yemek)', 'White bean stew', 'turkish_dishes', ['kuru fasulye', 'etli kuru fasulye']);
todo('nohut_yemegi', 'Nohut yemeği', 'Chickpea stew', 'turkish_dishes');
todo('etli_taze_fasulye', 'Etli taze fasulye', 'Green beans with meat', 'turkish_dishes');
todo('imam_bayildi', 'İmam bayıldı', 'İmam bayıldı', 'turkish_dishes');
todo('karniyarik', 'Karnıyarık', 'Karnıyarık', 'turkish_dishes');
todo('hunkar_begendi', 'Hünkar beğendi', 'Hünkar beğendi', 'turkish_dishes');
todo('musakka', 'Musakka', 'Moussaka (Turkish)', 'turkish_dishes', ['moussaka']);
todo('turlu', 'Türlü', 'Türlü (vegetable stew)', 'turkish_dishes');
todo('mucver', 'Mücver', 'Zucchini fritters', 'turkish_dishes');
todo('patlican_kizartmasi', 'Patlıcan kızartması', 'Fried eggplant', 'turkish_dishes');
todo('kisir', 'Kısır', 'Kısır (bulgur salad)', 'turkish_dishes');
todo('piyaz', 'Piyaz', 'Piyaz (bean salad)', 'turkish_dishes');
todo('coban_salata', 'Çoban salata', 'Shepherd\'s salad', 'turkish_dishes', ['çoban salatası']);
todo('haydari', 'Haydari', 'Haydari (yogurt dip)', 'turkish_dishes');
todo('ezme', 'Acılı ezme', 'Spicy tomato ezme', 'turkish_dishes', ['ezme']);
todo('ezogelin', 'Ezogelin çorbası', 'Ezogelin soup', 'soups', ['ezogelin']);
todo('yayla', 'Yayla çorbası', 'Yayla (yogurt) soup', 'soups');
todo('tarhana', 'Tarhana çorbası', 'Tarhana soup', 'soups', ['tarhana']);
todo('iskembe', 'İşkembe çorbası', 'Tripe soup', 'soups');
todo('sehriyeli_pilav', 'Şehriyeli pirinç pilavı', 'Rice pilaf with orzo', 'turkish_dishes');
todo('hamsi_tava', 'Hamsi tava', 'Pan-fried anchovies', 'meat_fish');
todo('balik_ekmek', 'Balık ekmek', 'Fish sandwich', 'turkish_dishes');
todo('midye_dolma', 'Midye dolma', 'Stuffed mussels', 'turkish_dishes');
todo('tantuni', 'Tantuni', 'Tantuni', 'turkish_dishes');
todo('kokorec', 'Kokoreç', 'Kokoreç', 'turkish_dishes');
todo('kumpir', 'Kumpir', 'Kumpir (stuffed baked potato)', 'turkish_dishes');
todo('tahin_pekmez', 'Tahin pekmez', 'Tahini and grape molasses', 'breakfast');
todo('helva', 'Tahin helvası', 'Tahini halva', 'sweets_snacks', ['helva', 'halva']);
todo('lokum', 'Lokum', 'Turkish delight', 'sweets_snacks', ['turkish delight']);
todo('kunefe', 'Künefe', 'Künefe', 'sweets_snacks');
todo('kadayif', 'Kadayıf', 'Kadayıf', 'sweets_snacks', ['tel kadayıf']);
todo('revani', 'Revani', 'Revani (semolina cake)', 'sweets_snacks');
todo('kazandibi', 'Kazandibi', 'Kazandibi', 'sweets_snacks');
todo('asure', 'Aşure', 'Aşure (Noah\'s pudding)', 'sweets_snacks');
todo('irmik_helvasi', 'İrmik helvası', 'Semolina halva', 'sweets_snacks');

export default foods;
