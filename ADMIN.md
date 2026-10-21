# ადმინ დეშბორდი

მისამართი: **https://shop.padelbade.com/admin/**

- **შეკვეთები**: ყველა შეკვეთა საიტიდან (სახელი, ტელეფონი, მისამართი, პროდუქცია, თანხა). სტატუსი: ახალი → დადასტურებული → დასრულებული, ან გაუქმებული. გაუქმებისას პროდუქცია ავტომატურად ბრუნდება მარაგში. სია ყოველ 30 წამში ახლდება.
- **მარაგები**: თითოეული პროდუქტის რაოდენობის შეცვლა (− / + ან ციფრის ჩაწერა), ინახება ავტომატურად. ჩანს, ვინ და როდის შეცვალა.
- შეკვეთის გაფორმებისას საიტი მარაგს თავად აკლებს; ორი კლიენტი ერთსა და იმავე ბოლო ჩოგანს ვერ იყიდის.

## პირველადი დაყენება (ერთხელ, ~10 წუთი)

1. შექმენი უფასო პროექტი: https://supabase.com → New project (რეგიონი: Frankfurt / eu-central-1).
2. **SQL Editor** → New query → ჩასვი ფაილის [`supabase/schema.sql`](supabase/schema.sql) მთელი შიგთავსი → **Run**.
   ეს ქმნის ცხრილებს, უსაფრთხოების წესებს და ავსებს მარაგს ახლანდელი კატალოგიდან.
3. **Project Settings → API**: დააკოპირე `Project URL` და `anon public` გასაღები და ჩასვი [`config.js`](config.js)-ში:
   ```js
   window.PB_CONFIG = {
     supabaseUrl: "https://xxxx.supabase.co",
     supabaseAnonKey: "eyJ..."
   };
   ```
   (`anon` გასაღები საჯაროა და ასე უნდა იყოს. **service_role** გასაღები არასოდეს ჩასვა საიტზე.)
4. **Authentication → Sign In / Providers → Email**: გამორთე **Allow new users to sign up**, რომ ანგარიშები მხოლოდ შენ შექმნა.

## თანამშრომლის დამატება

1. **Authentication → Users → Add user → Create new user**: ელფოსტა + პაროლი, მონიშნე **Auto Confirm User**.
2. **SQL Editor**-ში:
   ```sql
   insert into public.staff (email, name) values ('nino@example.com', 'ნინო');
   ```
   ელფოსტა პატარა ასოებით.

წაშლა: `delete from public.staff where email = 'nino@example.com';` (და სურვილისამებრ მომხმარებლის წაშლა Authentication → Users-დან).

## კარგია იცოდე

- სანამ `config.js` ცარიელია, საიტი ძველებურად მუშაობს: მარაგი `index.html`-დან, შეკვეთები არ ინახება.
- ახალი პროდუქტის დამატება: ჯერ `index.html`-ის `P` სიაში (როგორც აქამდე), შემდეგ ბაზაში:
  ```sql
  insert into public.products (id, cat, name, price, stock) values ('r15', 'racket', 'Bullpadel ...', 500, 2);
  ```
  ფასის შეცვლისას შეცვალე ორივეგან (`index.html` და `products.price`); შეკვეთის თანხას ბაზა ითვლის.
