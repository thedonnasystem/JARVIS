import { getPermalink } from './utils/permalinks';
import { SITE_DATA as S, BOOKING, BOOK_LABEL, PLACE } from './data/site';

const groups = (S.pricing || []).map((g: any) => ({ id: g.id, text: g.nav || g.title.split(' ').slice(-1)[0].replace(/^./, (c: string) => c.toUpperCase()), href: getPermalink(`/#${g.id}`) }));
const links = [{ text: 'Services', href: getPermalink('/#services') }, ...groups, { text: 'How it works', href: getPermalink('/#how-it-works') },
  { text: 'FAQ', href: getPermalink('/#faq') },
  // optional lead-magnet page (src/pages/[calculator].astro), only when site.json has a "calculator" block
  ...(S.calculator ? [{ id: 'calculator', text: S.calculator.nav || 'Calculator', href: getPermalink(`/${S.calculator.path || 'calculator'}`) }] : []),
  { text: 'Contact', href: getPermalink('/#contact') }];

// site.json "header_hide": section ids kept out of the top bar (still in the footer), so the bar fits on one line
const hide: string[] = (S as any).header_hide || [];
export const headerData = { links: links.filter((l: any) => !hide.includes(l.id)), actions: [{ text: (S.links?.booking_label_short as string) || BOOK_LABEL, href: BOOKING }] };

export const footerData = {
  links: [{ title: S.brand.name, links }],
  secondaryLinks: [
    { text: 'Terms', href: getPermalink('/terms') },
    { text: 'Privacy Policy', href: getPermalink('/privacy') },
  ],
  socialLinks: [],
  footNote: [S.brand.name, PLACE, 'All rights reserved.'].filter(Boolean).join(' · '),
};
