// The site's content comes from site.json, written by sites/build.py from sites/<slug>/site.json (Web Studio). Templates never hard-code copy.
import site from './site.json';

export const SITE_DATA = site as any;
export const BRAND = SITE_DATA.brand.name as string;
export const BOOKING = (SITE_DATA.links?.booking as string) || '#contact';
export const DEMO_PHONE = (SITE_DATA.links?.demo_phone as string) || '';
export const FX = SITE_DATA.variant === 'futuristic';
export const CONSENT = SITE_DATA.consent;
// Location is optional: a brand without brand.city/region shows no place anywhere (the legal contact carries the mailing address).
export const PLACE = [SITE_DATA.brand.city, SITE_DATA.brand.region].filter(Boolean).join(', ');
export const SENDER = String(CONSENT?.sender || '').replace(/(,\s*)+\./, '.');
// Theme: the art-direction layer on top of the variant. 'maison' (black, wine, metallic gold; WebGL liquid-metal orb, phone call demo, bento)
// needs the futuristic variant; its metal and wine colours come from brand.accent and brand.primary, so any brand can use it.
export const THEME = (FX && SITE_DATA.theme === 'maison') ? 'maison' : FX ? 'futuristic' : 'local';
export const MAISON = THEME === 'maison';
