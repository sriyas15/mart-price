const express = require('express');
const cors = require('cors');
const scraper = require('./scraper');

const app = express();
app.use(cors());
app.use(express.json());

const PORT = process.env.PORT || 4000;

// ---------------------------------------------------------------------------
// Curated Search Suggestions (Popular Chennai Grocery Items)
// ---------------------------------------------------------------------------
const COMMON_ITEMS = [
  'Amul Butter 100g',
  'Amul Butter 500g',
  'Amul Taaza Milk 500ml',
  'Amul Gold Milk 500ml',
  'Aashirvaad Atta 5kg',
  'Aashirvaad Atta 1kg',
  'Fortune Sunlite Sunflower Oil 1L',
  'Fortune Sunlite Sunflower Oil 5L',
  'Coca-Cola 750ml',
  'Coca-Cola 2L',
  'Thums Up 750ml',
  'Sprite 750ml',
  'Pepsi 750ml',
  "Lay's India's Magic Masala 50g",
  "Lay's Classic Salted 52g",
  'Tata Salt 1kg',
  'Maggi 2-Minute Noodles 420g',
  'Maggi 2-Minute Noodles 70g',
  'Nandini GoodLife Milk 500ml',
  'Eggs (Pack of 6)',
  'Eggs (Pack of 12)',
  'Onion 1kg',
  'Tomato Local 1kg',
  'Potato 1kg',
  'Banana Robusta 1kg',
  'Apple Shimla 1kg',
  'Curd Nandini 500ml',
  'Bread - Britannia White 400g',
  'Britannia Good Day Butter 200g',
  'Parle-G Biscuit 250g',
  'Surf Excel Matic Top Load 1kg',
  'Vim Dishwash Gel Lemon 500ml',
  'Dettol Liquid Handwash 200ml',
  'Colgate MaxFresh Toothpaste 150g',
  'Harpic Power Plus 500ml',
  'Rice - Ponni Boiled 5kg',
  'Tur Dal 1kg',
  'Sugar 1kg',
  'Tea - Brooke Bond Red Label 500g',
  'Coffee - Bru Instant 50g',
];

// ---------------------------------------------------------------------------
// Platform Config: fees, deep links, ETA
// ---------------------------------------------------------------------------
const PLATFORM_CONFIG = {
  Blinkit: {
    delivery: 25.0,
    handling: 2.0,
    gstRate: 0.18,
    eta: '10-15 mins',
    deepLink: (q) => `https://blinkit.com/s/?q=${encodeURIComponent(q)}`,
    scraper: 'scrapeBlinkit',
  },
  Zepto: {
    delivery: 25.0,
    handling: 6.0,
    gstRate: 0.18,
    eta: '8-10 mins',
    deepLink: (q) => `https://www.zeptonow.com/search?query=${encodeURIComponent(q)}`,
    scraper: 'scrapeZepto',
  },
  BigBasket: {
    delivery: 20.0,
    handling: 5.0,
    gstRate: 0.18,
    eta: '15-30 mins',
    deepLink: (q) => `https://www.bigbasket.com/ps/?q=${encodeURIComponent(q)}`,
    scraper: 'scrapeBigBasket',
  },
};

// ---------------------------------------------------------------------------
// 1. Search Auto-Suggestions Endpoint
// ---------------------------------------------------------------------------
app.get('/api/suggestions', (req, res) => {
  const q = (req.query.q || '').trim().toLowerCase();

  if (!q) {
    return res.json({ suggestions: COMMON_ITEMS.slice(0, 8) });
  }

  const filtered = COMMON_ITEMS
    .filter(item => item.toLowerCase().includes(q))
    .slice(0, 8);

  res.json({ suggestions: filtered.length ? filtered : [req.query.q.trim()] });
});

// ---------------------------------------------------------------------------
// 2. Multi-Product Comparison Endpoint (grouped by platform)
// ---------------------------------------------------------------------------
app.get('/api/compare', async (req, res) => {
  const { query, lat = '13.0418', lon = '80.2341' } = req.query;

  if (!query || query.trim() === '') {
    return res.status(400).json({
      success: false,
      message: 'Please enter a product name to search.',
    });
  }

  try {
    const results = {};
    const platforms = Object.keys(PLATFORM_CONFIG);

    // Fetch all platforms concurrently but stagger them slightly (2s apart)
    // to prevent bot detection and CPU throttling
    const fetchPromises = platforms.map(async (platform, index) => {
      await new Promise(r => setTimeout(r, index * 2500));
      const config = PLATFORM_CONFIG[platform];
      try {
        const products = await scraper[config.scraper](query);
        if (products && products.length > 0) {
          results[platform] = products.map((p) => ({
            platform,
            product_name: p.name,
            weight: p.weight,
            price: p.price,
            image_url: p.image_url || '',
            eta: config.eta,
            deep_link: config.deepLink(query),
          }));
        }
      } catch (err) {
        console.error(`${platform} scrape failed for query: ${query}`, err.message);
      }
    });

    await Promise.allSettled(fetchPromises);

    const totalProducts = Object.values(results).reduce((sum, arr) => sum + arr.length, 0);

    if (totalProducts === 0) {
      return res.status(404).json({
        success: false,
        message: `"${query}" is currently out of stock on all platforms.`,
      });
    }

    return res.json({
      success: true,
      query,
      location: { city: 'Chennai', lat, lon },
      results,
    });
  } catch (error) {
    console.error('Comparison error:', error.message);
    return res.status(500).json({
      success: false,
      message: 'Something went wrong while aggregating prices. Please try again.',
    });
  }
});

// ---------------------------------------------------------------------------
// Health check
// ---------------------------------------------------------------------------
app.get('/api/health', (_req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
app.listen(PORT, async () => {
  console.log(`\n  Mart Price Aggregator Backend`);
  console.log(`  Listening on http://localhost:${PORT}`);
  console.log(`  Endpoints:`);
  console.log(`    GET /api/health`);
  console.log(`    GET /api/suggestions?q=amul`);
  console.log(`    GET /api/compare?query=Amul+Butter&lat=13.0418&lon=80.2341\n`);
  
  await scraper.initBrowser();
});
