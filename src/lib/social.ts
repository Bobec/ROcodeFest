import type { IconName } from "@/lib/icons";

// The festival's social media accounts, in the order /contact lists them.
//
// TODO: the real addresses. Until one is filled in, the page shows that
// network as "în curând" rather than as a link: a guessed handle could
// be somebody else's account.
export const SOCIAL: { name: string; icon: IconName; url: string | null }[] = [
  { name: "Instagram", icon: "instagram", url: null },
  { name: "TikTok", icon: "tiktok", url: null },
  { name: "Facebook", icon: "facebook", url: null },
  { name: "YouTube", icon: "youtube", url: null },
];
