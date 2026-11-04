// Optional real-browser smoke driver; never prints the authorization URL or callback code.
import {pathToFileURL} from 'node:url';
import {createInterface} from 'node:readline';
const lines=createInterface({input:process.stdin})[Symbol.asyncIterator]();
const {chrome,url}=JSON.parse((await lines.next()).value);
const {chromium}=await import(pathToFileURL(process.env.HAKO_PLAYWRIGHT).href);
const browser=await chromium.launch({executablePath:chrome,headless:true});
let page; const responses=[]; const errors=[];
try {
 const context=await browser.newContext({ignoreHTTPSErrors:true});
 page=await context.newPage();
 page.on('pageerror',e=>errors.push(e.message.replace(/https?:\/\/[^ ]+/g,'[URL]')));
 page.on('response',r=>responses.push([new URL(r.url()).pathname.replace(/[A-Za-z0-9_-]{43}/g,':id'),r.status()]));
 await page.goto(url,{waitUntil:'domcontentloaded'});
 await page.waitForURL(u=>u.pathname==='/callback',{timeout:20000});
 if(!(await page.textContent('body')).includes('OIDC_BROWSER_CALLBACK_OK')) throw Error('missing callback marker');
 console.log('OIDC_BROWSER_CALLBACK_OK');
 } catch {
 console.error(JSON.stringify({title:await page?.title().catch(()=>''),status:await page?.locator('#status').textContent({timeout:500}).catch(()=>''),responses,errors}));
 process.exitCode=1;
}
finally { await browser.close(); }
process.exit(process.exitCode || 0);
