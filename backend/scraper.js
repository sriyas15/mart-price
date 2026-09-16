const puppeteer = require('puppeteer-extra');
const StealthPlugin = require('puppeteer-extra-plugin-stealth');
puppeteer.use(StealthPlugin());

let browser;

async function initBrowser() {
  browser = await puppeteer.launch({
    headless: "new",
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-blink-features=AutomationControlled']
  });
  console.log("Puppeteer Stealth Browser Initialized");
}

// ---------------------------------------------------------------------------
// Shared helper: extract multiple products from a page's DOM
// Returns an array of { name, price, weight } (up to `limit` items)
// ---------------------------------------------------------------------------
function buildExtractScript(limit = 8) {
  return (maxItems) => {
    const seen = new Set();
    const products = [];
    const elements = Array.from(document.querySelectorAll('div, a, span'))
      .filter(el => el.innerText && el.innerText.includes('₹') && el.innerText.length > 20 && el.innerText.length < 200);

    for (const el of elements) {
      if (products.length >= maxItems) break;
      const text = el.innerText;
      const priceMatch = text.match(/₹\s*(\d+)/);
      if (!priceMatch) continue;
      const price = parseFloat(priceMatch[1]);
      if (price <= 5 || price >= 5000) continue;

      const lines = text.split('\n').map(l => l.trim()).filter(l => l.length > 0);
      let name = lines.find(l =>
        l.length > 4 &&
        !l.includes('% OFF') &&
        !l.includes('MINS') &&
        !l.includes('₹') &&
        l !== 'ADD' &&
        l !== 'OFF'
      ) || null;
      if (!name) continue;

      // Deduplicate by name+price
      const key = `${name}__${price}`;
      if (seen.has(key)) continue;
      seen.add(key);

      const weightMatch = text.match(/(\d+\s*(g|kg|ml|l|pc|pcs|pack))/i);
      const weight = weightMatch ? weightMatch[1] : 'Standard';

      // Attempt to find the product image by traversing up the DOM
      let imageUrl = '';
      let curr = el;
      for (let i = 0; i < 5; i++) {
        if (!curr) break;
        const img = curr.querySelector('img');
        if (img && img.src && img.src.startsWith('http') && !img.src.includes('icon') && !img.src.includes('logo')) {
          imageUrl = img.src;
          break;
        }
        curr = curr.parentElement;
      }

      products.push({ name, price, weight, image_url: imageUrl });
    }
    return products.length > 0 ? products : null;
  };
}

// ---------------------------------------------------------------------------
// Retry logic to handle slow-loading skeleton screens (e.g. BigBasket)
// ---------------------------------------------------------------------------
async function extractWithRetry(page, limit = 8, retries = 6) {
  for (let i = 0; i < retries; i++) {
    const data = await page.evaluate(buildExtractScript(limit), limit);
    if (data && data.length > 0) return data;
    await new Promise(r => setTimeout(r, 2000)); // wait 2s before retry
  }
  return null;
}

// ---------------------------------------------------------------------------
// Blinkit Scraper — returns array of products
// ---------------------------------------------------------------------------
async function scrapeBlinkit(query) {
  if (!browser) return null;
  const page = await browser.newPage();
  try {
    await page.goto(`https://blinkit.com/s/?q=${encodeURIComponent(query)}`, { waitUntil: 'domcontentloaded', timeout: 20000 });
    const data = await extractWithRetry(page, 8);
    return data;
  } catch (e) {
    console.error('Blinkit scrape error:', e.message);
    return null;
  } finally {
    await page.close();
  }
}

// ---------------------------------------------------------------------------
// Zepto Scraper — returns array of products
// ---------------------------------------------------------------------------
async function scrapeZepto(query) {
  if (!browser) return null;
  const page = await browser.newPage();
  try {
    await page.goto(`https://www.zeptonow.com/search?query=${encodeURIComponent(query)}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    const data = await extractWithRetry(page, 8);
    return data;
  } catch (e) {
    console.error('Zepto scrape error:', e.message);
    return null;
  } finally {
    await page.close();
  }
}

// ---------------------------------------------------------------------------
// BigBasket Scraper — using internal JSON Web API (Option 1)
// ---------------------------------------------------------------------------
async function scrapeBigBasket(query) {
  if (!browser) return null;
  const page = await browser.newPage();
  try {
    // Navigate to homepage first to get Akamai cookies and clear Cloudflare
    await page.goto('https://www.bigbasket.com/', { waitUntil: 'domcontentloaded', timeout: 20000 });

    // Fetch the internal JSON API directly from within the browser context
    const data = await page.evaluate(async (searchQuery) => {
      try {
        const url = `https://www.bigbasket.com/listing-svc/v2/products?type=ps&slug=${encodeURIComponent(searchQuery)}&page=1`;
        const r = await fetch(url);
        const j = await r.json();
        
        if (!j || !j.tabs || !j.tabs[0] || !j.tabs[0].product_info || !j.tabs[0].product_info.products) {
          return null;
        }
        
        const rawProducts = j.tabs[0].product_info.products.slice(0, 8);
        return rawProducts.map(p => ({
          name: ((p.brand && p.brand.name ? p.brand.name + ' ' : '') + p.desc).trim(),
          weight: p.w || '',
          price: parseFloat(p.pricing.discount.prim_price.sp || 0),
          image_url: p.images && p.images.length > 0 ? p.images[0].m : ''
        }));
      } catch (err) {
        return null;
      }
    }, query);

    return data;
  } catch (e) {
    console.error('BigBasket API scrape error:', e.message);
    return null;
  } finally {
    await page.close();
  }
}

module.exports = { initBrowser, scrapeBlinkit, scrapeZepto, scrapeBigBasket };
