# Altitude Outfitters — Power BI Case Study Data Pack

> ⚠️ **Bütün data sintetikdir (süni yaradılıb).** Şirkət, müştərilər, sifarişlər fiktivdir. Portfoliyada bunu açıq yaz: *"Fictional dataset created for demonstration purposes"*. Real müştəri datası kimi təqdim etmə.

## 1. Biznes ssenarisi

**Altitude Outfitters** — dağ/açıq hava (outdoor) avadanlıqları satan fiktiv, çox kanallı şirkətdir.
- **8 ölkə:** DE, FR, NL, GB, US, TR, AZ, AE (AE 2024-03-dən açılıb)
- **4 kanal:** Online mağaza (8), Marketplace (5), Fiziki mağaza (6), B2B topdan satış (3)
- **207 məhsul**, 7 kateqoriya, 10 təchizatçı, 3 anbar
- **6 valyuta** (USD, EUR, GBP, TRY, AZN, AED) — məbləğlər yerli valyutadadır!
- **Dövr:** 2023-01-01 → 2026-09-30 (45 ay). Hədəf və büdcə 2026-12-ə qədər var (gələcək aylar üçün faktiki data yoxdur).
- **Miqyas:** ~91 min sifariş, ~146 min sətir, ~39 min müştəri, ümumi xalis gəlir ≈ 22M$.

Sənin işin: bu 17 faylı birləşdirib rəhbərlik üçün qərar verməyə kömək edən bir hesabat qurmaqdır.

## 2. Fayllar

| Fayl | Sətir | Qranulyarlıq / məzmun |
|---|---|---|
| `fact_orders` | 91,500 | 1 sətir = 1 sifariş (başlıq). Status, çatdırılma, carrier, ödəniş |
| `fact_order_lines` | 145,767 | 1 sətir = sifarişdəki 1 məhsul. Qiymət (yerli valyuta), endirim, **maya dəyəri (USD)** |
| `fact_returns` | 10,601 | 1 sətir = bir sətir üzrə qaytarma. Səbəb, vəziyyət, refund |
| `fact_support_tickets` | 5,792 | Müştəri dəstək bileti. Cavab/həll vaxtı, CSAT (1–5) |
| `fact_inventory_snapshot` | 23,552 | Ay sonu: məhsul × anbar. Stok, sifarişdə olan, stockout günləri |
| `fact_marketing_spend` | 53,847 | **Gündəlik**: kanal × ölkə. Xərc, klik, platformanın bildirdiyi konversiya |
| `fact_web_sessions` | 21,461 | **Həftəlik** (həftə bazar günü başlayır): ölkə × cihaz × mənbə. Funnel |
| `fact_targets` | 2,586 | **Aylıq** gəlir hədəfi: ölkə × kateqoriya (2026-12-ə qədər) |
| `fact_marketing_budget` | 2,085 | **Aylıq** marketinq büdcəsi: ölkə × kanal (2026-12-ə qədər) |
| `fx_rates` | 270 | Aylıq orta məzənnə: `rate_to_usd` (1 yerli vahid = neçə USD) |
| `dim_customers` | 39,529 | Müştəri (313 təkrarlanan sətir daxil — bax: 5) |
| `dim_products` | 207 | Məhsul, kateqoriya, brend, təchizatçı, cari qiymət/maya |
| `dim_stores` | 22 | Mağaza/kanal, marketplace komissiyası, ödəniş haqqı |
| `dim_geography` | 8 | Ölkə, region, valyuta, koordinat (xəritə üçün) |
| `dim_promotions` | 33 | Kampaniyalar, endirim %, kanal/ölkə/kateqoriya əhatəsi |
| `dim_suppliers` | 10 | Təchizatçı, lead time, keyfiyyət reytinqi |
| `dim_warehouses` | 3 | Anbarlar |
| `dim_marketing_channels` | 9 | Kanal qrupu (Paid/Owned/Organic/Partner) |

**Özün yaratmalı olduğun cədvəllər:** `DimDate` (DAX `CALENDAR`, 2023-01-01 → 2026-12-31, *Mark as date table*), `DimCategory` (məhsullardan distinct), `Measures` (boş cədvəl, bütün ölçülər orada), parametr cədvəlləri.

## 3. Tövsiyə olunan əlaqələr (relationships)

- `fact_order_lines[order_id]` → `fact_orders` · `[product_id]` → `dim_products` → `dim_suppliers`
- `fact_orders[customer_id]` → `dim_customers` (**~19% boşdur** — marketplace sifarişləri anonimdir)
- `fact_orders[store_id]` → `dim_stores` · `[ship_to_country]` → `dim_geography` · `[promo_id]` → `dim_promotions`
- `fact_returns[order_line_id]` → `fact_order_lines` · `fact_support_tickets[order_id]` → `fact_orders`
- `fact_inventory_snapshot` → `dim_products`, `dim_warehouses`, tarix → `DimDate` (**semi-additive**: cəmləmə yox, son ay/tarix)
- `fact_marketing_spend`, `fact_marketing_budget`, `fact_web_sessions`, `dim_customers[acquisition_channel]` → `dim_marketing_channels` və `dim_geography`
- `fact_targets` → `DimDate` (ayın 1-i), `dim_geography`, `DimCategory`
- `fx_rates`: ya Power Query-də (month_start + currency_code ilə merge), ya DAX-da `LOOKUPVALUE` ilə.

**Dizayn qərarı:** sifariş başlığı (orders) və sətirlər (lines) ayrıdır. Ya orders-in lazımi sütunlarını (tarix, mağaza, ölkə, valyuta, status) lines-ə Power Query-də birləşdir, ya da tək istiqamətli əlaqə saxla. Hansını seçdiyini və niyə seçdiyini sənədləşdir.

## 4. Biznes qaydaları və düsturlar

- **Net Revenue** = `quantity × unit_price_local × (1 − discount_pct)` → **USD-ə çevir:** sifariş ayının `rate_to_usd` məzənnəsi ilə. `Cancelled` sifarişlər **daxil edilmir**.
- **COGS (USD)** = `quantity × unit_cost_usd` (artıq USD-dir, satış anındakı faktiki maya).
- **Gross Margin** = Net Revenue − COGS.
- **Contribution Margin** (tövsiyə) = Gross Margin − marketplace komissiyası (`dim_stores`) − ödəniş haqqı − (shipping_cost_usd − alınan çatdırılma haqqı) − refund.
- `shipping_fee_local` və `refund_amount_local` yerli valyutadadır; `shipping_cost_usd` USD-dir. Refund-u hansı aya aid edəcəyini (sifariş ayı / qaytarma ayı) özün seç və qeyd et.
- **Gecikmə** = `delivery_date > promised_delivery_date` (yalnız `Completed`, `Ship to Home`).
- **CAC** = kanal xərci / həmin kanaldan gələn yeni müştəri sayı (`acquisition_channel`, signup ayı, ölkə).
- Fiziki mağaza sifarişləri (`In-Store`) üçün çatdırılma = sifariş günü.
- Son günlərin sifarişləri `Shipped`/`Processing` statusundadır (hələ çatdırılmayıb).

## 5. Bilərəkdən qoyulmuş "çirkli data" (Power Query-də həll et)

1. **dim_customers:** 313 tam təkrarlanan sətir · `gender` variantları (Female/F/female/Woman, Male/M/male/Man, boş) · `city`-də artıq boşluq və BÖYÜK hərflər · `birth_date` boş (~1,200) və `1900-01-01` saxta dəyərlər (365).
2. **dim_products:** `category` bəzən kiçik hərflə · `subcategory`-də sonda boşluq.
3. **fact_orders:** `order_datetime` **iki formatda** (ISO `2024-03-05 14:20:11` və köhnə kassa sistemi `05.03.2024 14:20` — 2,085 sətir) · `payment_method`: "Credit Card" / "Credit card" · `customer_id` boş (marketplace) · çatdırılma sahələri ləğv olunmuş/hələ çatdırılmamış sifarişlərdə boşdur.
4. **fact_order_lines:** 40 tam təkrarlanan sətir (`order_line_id` təkrarlanır → əlaqə xətası verəcək) · `discount_pct` boş (~0.5%, 0 kimi qəbul et).
5. **fact_marketing_spend:** kanal adları uyğunsuz ("Facebook Ads", "meta ads", "google ads") · `spend_usd` boş (150 sətir).
6. **Fərqli qranulyarlıq:** gündəlik (marketinq), həftəlik (sessiyalar), aylıq (hədəf, büdcə, FX), ay sonu (stok), sətir səviyyəsi (satış).
7. **Çox valyuta:** satış məbləğləri 6 valyutada.

## 6. Datada gizlənmiş hekayələr (dashboard-un "insight" səhifələri üçün)

1. **Böyümə + mövsümilik:** Noyabr–Dekabr zirvə, Black Friday həftəsi; kateqoriya mövsümiliyi (çadırlar yay, qış idmanı qış).
2. **Black Friday endirimi ildən-ilə dərinləşir:** 20% (2023) → 25% (2024) → 30% (2025). Marjaya təsiri nədir? BF ilə gələn müştərilərin təkrar alış nisbəti də aşağıdır (~43% vs ~51%).
3. **Türkiyə və məzənnə:** TRY-də gəlir sürətlə artır, amma TRY-nin ucuzlaşması USD gəlirini aşağı çəkir. *Constant currency* analizi qur.
4. **Çadırlar + təchizatçı S05:** 2025-03-dən maya +14%, kateqoriya marjası ~46% → ~37–41%, qüsurlu qaytarmaların payı artır, 2025-ci yayda stockout-lar.
5. **Marketplace illüziyası:** ümumi marja yüksək görünür, amma ~14–17% komissiyadan sonra Web-dən xeyli zəifdir.
6. **Marketinq effektivliyi:** Meta CAC artır, TikTok ucuzdur amma müştəriləri az qayıdır (Email/Referral ən sadiq). Platformalar real yeni müştəri sayından **~1.5–2.4× çox konversiya** bildirir (over-attribution).
7. **Pareto:** ən yaxşı 10% müştəri owned kanallarda gəlirin ~43%-ni verir. RFM və LTV üçün idealdır.
8. **Çatdırılma probleması:** SwiftCargo (TR/AZ) 2025-06-dan sonra gecikir (~12–19% → ~55–60%). Gecikmiş sifarişlərdə CSAT ~3.1, vaxtında olanlarda ~4.1; dəstək biletləri artır.
9. **Qaytarmalar:** Footwear ən yüksək qaytarma (~12–14%), "Wrong size/fit" əsas səbəb. Bir məhsul (Nordvik Apex Trail Runner Men's) anomal dərəcədə çox qayıdır.
10. **Stok:** zirvə mövsümdə stockout-lar (itirilmiş satış) və eyni zamanda ~8% "ölü stok" (satış düşür, stok yığılır).
11. **Hədəf vs faktiki:** TR hədəfləri 2025-ci ilin ikinci yarısından qaçırılır; AZ hədəfi aşır; Meta büdcədən çox xərclənir, TikTok az.
12. **Genişlənmə:** AE bazarı (2024-03), New York mağazası (2024-05), Dubai mağazası (2025-02), Baku mağazası (2023-06).

## 7. Tövsiyə olunan hesabat strukturu

1. **Executive Summary** — KPI kartları (YoY, vs Target), trend, xəritə, "Top insights" mətn bloku
2. **Sales & Margin** — kanal/ölkə/kateqoriya, marja körpüsü (waterfall), endirim təsiri, Pareto (ABC)
3. **Customers** — cohort retention, RFM seqmentləri, LTV, acquisition channel müqayisəsi
4. **Marketing** — CAC, ROAS, platform vs real, funnel (sessions → order), büdcə vs faktiki
5. **Operations** — çatdırılma SLA, carrier müqayisəsi, qaytarmalar, stok örtüyü (days of cover), CSAT
6. **Budget vs Actual** — variance, şərti formatlama, proqnoz (forecast)

**Fərqləndirən texniki elementlər:** star schema + sənədləşdirilmiş model · `DimDate` + fiscal/YTD/YoY/MTD ölçüləri · **Field Parameters** (ölçü/ölçü dəyişdirmə) · valyuta seçici (USD / yerli) · What-if parametri (endirim, FX) · **Drill-through + Tooltip səhifələri** · Bookmark naviqasiya · Row-Level Security (region üzrə) · Performance Analyzer ilə optimallaşdırma · ölçü qovluqları və adlandırma qaydası · "About / Data Model" sənədləşmə səhifəsi.

**Power Query tövsiyəsi:** hər mənbə üçün `raw` (referans) → `clean` (təmizlənmiş) sorğu; təkrar əməliyyatları funksiyaya çevir; tarix formatlarını `Locale` ilə düzgün parse et; hər addıma ad ver.

## 8. Portfoliyada necə göstər

Cover şəkli (1920×1080), 10–15 san. GIF (filtr klikləri), model diaqramı ekran görüntüsü və qısa **Problem → Yanaşma → Nəticə** mətni. Mütləq qeyd et: *data sintetikdir*.
