export type BotStatus = 'pending' | 'logging_in' | 'connecting' | 'online' | 'reconnecting' | 'expired' | 'stopped';
export type MessageStatus = 'received' | 'queued' | 'sending' | 'provider_accepted' | 'failed' | 'unknown';
export const notificationChannels = ['wechat', 'apns'] as const;
export type NotificationChannel = typeof notificationChannels[number];
export const channelLabels: Record<NotificationChannel, string> = { wechat: '微信', apns: 'Apple Push' };
export type DeliveryStatus = Exclude<MessageStatus, 'received'>;
export interface NotificationDelivery {
  id: string; channel: NotificationChannel; targetId: string; targetName: string; messageId: string | null;
  status: DeliveryStatus; code: string | null; error: string | null; updatedAt: number;
}
export interface NotificationResult {
  notificationId: string; status: DeliveryStatus; deliveries: NotificationDelivery[];
}
export interface PushDevice {
  id: string; name: string; environment: 'production' | 'sandbox';
  status: 'active' | 'invalid' | 'revoked'; updatedAt: number;
}
export interface PushConfig { teamId: string; keyId: string; bundleId: string; source: 'environment' | 'admin' }
export interface PushChannel { configured: boolean; config: PushConfig | null; device: PushDevice | null }
export interface ChannelMessage {
  id: string; channel: NotificationChannel; direction: 'in' | 'out'; botId: string | null;
  title: string | null; text: string; targetName: string; source: string; status: MessageStatus; error: string | null; createdAt: number;
}
export interface WebHookRouting {
  botId: string | null; apnsEnabled: boolean;
}
export interface Bot {
  id: string; name: string; platform: string; status: BotStatus; note: string;
  accountId: string | null; lastError: string | null; lastSeenAt: number | null;
  createdAt: number; hasCredentials: boolean; unread: number; webhookCount: number;
  conversationId: string | null; conversationName: string | null;
}
export interface Conversation {
  id: string; botId: string; peerId: string; name: string; remark: string;
  unread: number; lastMessage: string;
  lastMessageAt: number; hasContext: boolean;
}
export interface Message {
  id: string; botId: string; conversationId: string; direction: 'in' | 'out';
  type: string; text: string; status: MessageStatus; source: string;
  webhookId: string | null; error: string | null; createdAt: number; updatedAt: number;
  imageUrl?: string | null;
}
export interface WebHookMessage extends Message {
  botName: string; conversationName: string; peerId: string; botDeleted: boolean;
}
export interface WebHookMessagePage {
  items: WebHookMessage[]; nextCursor: string | null; total: number;
}
export interface WebHook extends WebHookRouting {
  id: string; name: string; conversationId: string | null; enabled: boolean;
  tokenHint: string; rateLimit: number; expiresAt: number | null; createdAt: number;
  botName: string | null; conversationName: string | null; requestCount: number; failureCount: number; lastUsedAt: number | null;
}
export interface WebHookRequest {
  id: string; webhookId: string; messageId: string | null; status: string;
  summary: string; error: string | null; ip: string; createdAt: number; deliveries?: NotificationDelivery[];
}
export interface LoginSession {
  id: string; botId: string; status: string; qrImage: string; qrContent: string; expiresAt: number; error: string | null;
}
export interface BotLog { id: string; level: string; event: string; detail: string; createdAt: number }
export interface Overview {
  channels: { id: NotificationChannel; status: 'ready' | 'offline' | 'not_configured' | 'device_required' }[];
  receivedToday: number; sentToday: number;
  failedToday: number; queued: number; webhooks: number;
  recentMessages: ChannelMessage[];
  activity: { date: string; incoming: number; outgoing: number }[];
}
