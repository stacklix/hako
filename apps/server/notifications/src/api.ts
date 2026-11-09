export class ApiError extends Error {
  constructor(message: string, public code: string, public status: number) { super(message); }
}

let csrf = '';
export async function useHakoSession() {
  const response = await fetch('/admin/api/session', { credentials: 'same-origin', cache: 'no-store' });
  if (!response.ok) throw new ApiError('Hako 管理会话已到期，请重新登录', 'ADMIN_LOGIN_REQUIRED', response.status);
  const data: { csrfToken: string } = await response.json();
  csrf = data.csrfToken;
}

export async function api<T>(path: string, options: RequestInit = {}): Promise<T> {
  const mutation = options.method !== undefined && options.method !== 'GET';
  const response = await fetch('/admin/api/notifications' + path, {
    ...options, credentials: 'same-origin', cache: 'no-store',
    headers: {
      ...(mutation ? { 'X-CSRF-Token': csrf, 'Content-Type': 'application/json' } : {}),
      ...options.headers,
    },
  });
  const data = response.status === 204 ? undefined : await response.json();
  if (!response.ok) {
    if (response.status === 401) window.dispatchEvent(new Event('unauthorized'));
    throw new ApiError(data?.message || '请求失败', data?.code || data?.error || 'REQUEST_ERROR', response.status);
  }
  return data as T;
}
export const post = <T>(path: string, body?: unknown) => api<T>(path, { method: 'POST', body: JSON.stringify(body ?? {}) });
export const patch = <T>(path: string, body: unknown) => api<T>(path, { method: 'PATCH', body: JSON.stringify(body) });
export const remove = (path: string) => api(path, { method: 'DELETE' });
