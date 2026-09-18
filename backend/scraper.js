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
// Helper: parse weight from text, preferring specific units over "pack"
// ---------------------------------------------------------------------------
function parseWeight(text) {
  // First try "1 pack (250 ml)" → extract "250 ml"
  const fullPackMatch = text.match(/\d+\s*pack\s*\((\d+\s*(ml|g|kg|l))\)/i);
  if (fullPackMatch) return fullPackMatch[1];
  // Then try specific units
  const specific = text.match(/(\d+\s*(ml|g|kg|l)\b)/i);
  if (specific) return specific[1];
  // Fall back to pack/pcs
  const generic = text.match(/(\d+\s*(pc|pcs|pack)\b)/i);
  if (generic) return generic[1];
  return 'Standard';
}

// ---------------------------------------------------------------------------
// Retry wrapper: run an evaluate function with retries for skeleton screens
// ---------------------------------------------------------------------------
async function retryEvaluate(page, evalFn, retries = 6) {
  for (let i = 0; i < retries; i++) {
    const data = await page.evaluate(evalFn);
    if (data && data.length > 0) return data;
    await new Promise(r => setTimeout(r, 2000));
  }
  return null;
}

// ---------------------------------------------------------------------------
// Blinkit Scraper — API Interception (Bypasses lazy loading completely)
// ---------------------------------------------------------------------------
async function scrapeBlinkit(query) {
  if (!browser) return null;
  const page = await browser.newPage();
  try {
    let apiData = null;
    page.on('response', async res => {
      const url = res.url();
      if (url.includes('/v1/layout/search?q=') && !apiData) {
        try {
          apiData = await res.json();
        } catch (e) { }
      }
    });

    await page.goto(`https://blinkit.com/s/?q=${encodeURIComponent(query)}`, { waitUntil: 'networkidle2', timeout: 20000 });

    if (apiData && apiData.response && apiData.response.snippets) {
      const products = [];
      const seen = new Set();
      
      for (const snippet of apiData.response.snippets) {
        if (snippet.widget_type === 'product_card_snippet_type_2' || snippet.widget_type === 'product_card_snippet') {
          const d = snippet.data;
          if (!d) continue;

          const name = d.name ? d.name.text : null;
          let priceText = d.normal_price ? d.normal_price.text : (d.mrp ? d.mrp.text : null);
          const weight = d.variant ? d.variant.text : 'Standard';
          const imageUrl = d.image ? d.image.url : '';

          if (!name || !priceText) continue;

          const priceMatch = priceText.match(/(\d+)/);
          if (!priceMatch) continue;
          const price = parseFloat(priceMatch[1]);
          if (price <= 5 || price >= 5000) continue;

          const key = `${name}__${price}`;
          if (seen.has(key)) continue;
          seen.add(key);

          // Check stock status (generic server location)
          let inStock = true;
          if (d.out_of_stock === true || (d.inventory_status && d.inventory_status !== 'IN_STOCK')) {
            inStock = false;
          }

          products.push({ name, price, weight, image_url: imageUrl, in_stock: inStock });
        }
      }
      return products.length > 0 ? products : null;
    }
    
    return null;
  } catch (e) {
    console.error('Blinkit API scrape error:', e.message);
    return null;
  } finally {
    await page.close();
  }
}

// ---------------------------------------------------------------------------
// Zepto Scraper — site-specific card extraction using <a> link cards
// ---------------------------------------------------------------------------
async function scrapeZepto(query) {
  if (!browser) return null;
  const page = await browser.newPage();
  try {
    await page.goto(`https://www.zeptonow.com/search?query=${encodeURIComponent(query)}`, { waitUntil: 'networkidle2', timeout: 30000 });

    const data = await retryEvaluate(page, () => {
      const seen = new Set();
      const products = [];

      // Zepto product cards are <a> links with href containing product URLs
      const linkCards = Array.from(document.querySelectorAll('a')).filter(a => {
        const t = a.innerText || '';
        return t.includes('₹') && t.length > 30 && t.length < 300;
      });

      for (const card of linkCards) {
        const text = card.innerText;
        const priceMatch = text.match(/₹\s*(\d+)/);
        if (!priceMatch) continue;
        const price = parseFloat(priceMatch[1]);
        if (price <= 5 || price >= 5000) continue;

        const lines = text.split('\n').map(l => l.trim()).filter(l => l.length > 0);
        const name = lines.find(l =>
          l.length > 4 &&
          !l.includes('% OFF') &&
          !l.includes('MINS') &&
          !l.includes('₹') &&
          l !== 'ADD' &&
          l !== 'OFF'
        );
        if (!name) continue;

        const key = `${name}__${price}`;
        if (seen.has(key)) continue;
        seen.add(key);

        // Weight: parse from text, preferring specific units
        const fullPackMatch = text.match(/\d+\s*pack\s*\((\d+\s*(ml|g|kg|l))\)/i);
        const specific = text.match(/(\d+\s*(ml|g|kg|l)\b)/i);
        const generic = text.match(/(\d+\s*(pc|pcs|pack)\b)/i);
        const weight = fullPackMatch ? fullPackMatch[1] : specific ? specific[1] : generic ? generic[1] : 'Standard';

        // Image: find the real product image within this card (not Ad images)
        const imgs = Array.from(card.querySelectorAll('img')).filter(img =>
          img.src &&
          img.src.startsWith('http') &&
          !img.src.includes('Ad.png') &&
          !img.src.includes('icon') &&
          !img.src.includes('logo')
        );
        const imageUrl = imgs.length > 0 ? imgs[0].src : '';

        // Check if out of stock text is on the card
        const isOOS = lines.some(l => l.toLowerCase().includes('out of stock') || l.toLowerCase().includes('currently unavailable'));

        products.push({ name, price, weight, image_url: imageUrl, in_stock: !isOOS });
      }
      return products.length > 0 ? products : null;
    }, 8);

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
        
        const rawProducts = j.tabs[0].product_info.products.slice(0, 40);
        return rawProducts.map(p => ({
          id: p.id,
          name: ((p.brand && p.brand.name ? p.brand.name + ' ' : '') + p.desc).trim(),
          weight: p.w || '',
          price: parseFloat(p.pricing.discount.prim_price.sp || 0),
          image_url: p.images && p.images.length > 0 ? p.images[0].m : '',
          in_stock: p.availability ? p.availability.avail_status !== 0 : true
        }));
      } catch (err) {
        return null;
      }
    }, query);

    if (data) return data;
  } catch (e) {
    console.error('BigBasket API scrape error:', e.message);
  } finally {
    await page.close();
  }

  // Removed mock fallback as per user request to return app to original state
}

module.exports = { initBrowser, scrapeBlinkit, scrapeZepto, scrapeBigBasket };
