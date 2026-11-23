// The site's content comes from site.json, written by sites/build.py from sites/<slug>/site.json (Web Studio). Templates never hard-code copy.
import site from './site.json';

export const SITE_DATA = site as any;
export const BRAND = SITE_DATA.brand.name as string;
export const BOOKING = (SITE_DATA.links?.booking as string) || '#contact';
export const DEMO_PHONE = (SITE_DATA.links?.demo_phone as string) || '';
export const FX = SITE_DATA.variant === 'futuristic';
export const CONSENT = SITE_DATA.consent;
