// Builds the text of each notification. Pure, so it is unit tested with Node.
//
// Privacy rule: a note's words appear only when `preview` is non-null, and the
// database only supplies a preview for recipients who turned previews on.

export interface ClaimedNotification {
  id: number;
  user_id: string;
  category: "new_note" | "surprise" | "important_date" | "pairing" | "account" | "sync";
  payload: Record<string, unknown>;
  tokens: { token: string; environment: "sandbox" | "production" }[];
  widget_push?: { token: string; environment: "sandbox" | "production" }[];
  sender_name: string;
  preview: string | null;
  date_title: string | null;
}

export interface NotificationText {
  title: string;
  body: string;
  data: Record<string, string>;
}

export function notificationText(item: ClaimedNotification): NotificationText | null {
  const name = item.sender_name?.trim() || "Your partner";
  const data: Record<string, string> = {};
  if (typeof item.payload.note_id === "string") data.note_id = item.payload.note_id;
  if (typeof item.payload.date_id === "string") data.date_id = item.payload.date_id;

  switch (item.category) {
    case "new_note":
      return {
        title: name,
        body: item.preview?.trim() || (item.preview === "" ? "Sent you something to look at." : "Left you a note."),
        data,
      };
    case "surprise":
      return {
        title: `A surprise from ${name}`,
        body: item.preview?.trim() || "Open it when you have a moment.",
        data,
      };
    case "important_date": {
      if (!item.date_title) return null; // the date was deleted before the reminder went out
      const days = Number(item.payload.days_left ?? 0);
      const when = days <= 0 ? "is today" : days === 1 ? "is tomorrow" : `is in ${days} days`;
      return { title: item.date_title, body: `${item.date_title} ${when}.`, data };
    }
    case "pairing":
      return item.payload.event === "accepted"
        ? { title: "You’re connected", body: `${name} accepted your invitation.`, data }
        : { title: "Invitation declined", body: "Your invitation wasn’t accepted. You can send a new one.", data };
    case "account":
      return item.payload.event === "space_ended"
        ? { title: "Your shared space was closed", body: "Your partner unlinked. Your account is unchanged.", data }
        : null;
    default:
      return null;
  }
}
