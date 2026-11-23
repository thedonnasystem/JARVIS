import { getPermalink } from './utils/permalinks';
import { SITE_DATA as S, BOOKING } from './data/site';

const groups = (S.pricing || []).map((g: any) => ({ text: g.title.split(' ').slice(-1)[0].replace(/^./, (c: string) => c.toUpperCase()), href: getPermalink(`/#${g.id}`) }));
const links = [{ text: 'Services', href: getPermalink('/#services') }, ...groups, { text: 'How it works', href: getPermalink('/#how-it-works') },
  { text: 'FAQ', href: getPermalink('/#faq') }, { text: 'Contact', href: getPermalink('/#contact') }];

export const headerData = { links, actions: [{ text: 'Book a demo', href: BOOKING }] };

export const footerData = {
  links: [{ title: S.brand.name, links }],
  secondaryLinks: [
    { text: 'Terms', href: getPermalink('/terms') },
    { text: 'Privacy Policy', href: getPermalink('/privacy') },
  ],
  socialLinks: [],
  footNote: `${S.brand.name} · ${S.brand.city}, ${S.brand.region} · All rights reserved.`,
};
