import { createContext, useContext, useEffect, useId, useRef, useState } from 'react';
import { Info, X } from 'lucide-react';

const DialogContext = createContext(null);
export const useDialog = () => useContext(DialogContext);

export function Button({ children, primary, icon, className = '', busy, disabled, ...props }) {
  return <button type="button" className={`${icon ? 'dp-icon' : 'dp-button'} ${primary ? 'dp-primary' : ''} ${className}`} disabled={disabled || busy} {...props}>{busy ? '处理中…' : children}</button>;
}

export function Panel({ title, description, action, children }) {
  return <section className="dp-panel"><div className="dp-panelhead"><div><h2>{title}</h2>{description && <p>{description}</p>}</div>{action}</div>{children}</section>;
}

export function Field({ label, hint, children, ...props }) {
  const id = useId();
  return <label className="dp-field" htmlFor={children ? undefined : id}>{label}{children || <input id={id} {...props} />}{hint && <small>{hint}</small>}</label>;
}

export function Note({ children }) {
  return <div className="dp-note"><Info aria-hidden="true" /><span>{children}</span></div>;
}

export function Badge({ children, neutral }) {
  return <span className={`dp-badge ${neutral ? 'neutral' : ''}`}>{children}</span>;
}

export function Tabs({ items, value, onChange }) {
  return <div className="dp-tabs" role="tablist">{items.map(([key, label, Icon]) => <button type="button" role="tab" aria-selected={value === key} className={`dp-tab ${value === key ? 'active' : ''}`} key={key} onClick={() => onChange(key)} onKeyDown={(event) => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const index = items.findIndex(([item]) => item === key);
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : (index + (event.key === 'ArrowRight' ? 1 : -1) + items.length) % items.length;
    onChange(items[next][0]); event.currentTarget.parentElement.children[next].focus();
  }}>{Icon && <Icon aria-hidden="true" />}{label}</button>)}</div>;
}

export function SwitchRow({ title, description, checked, onChange, disabled }) {
  return <div className="dp-switchrow"><div><strong>{title}</strong>{description && <p>{description}</p>}</div><label className="dp-switch"><input type="checkbox" aria-label={title} checked={!!checked} disabled={disabled} onChange={(event) => onChange(event.target.checked)} /><span /></label></div>;
}

export function SummaryRow({ label, description, children }) {
  return <div className="dp-connection-row"><div><strong>{label}</strong>{description && <p>{description}</p>}</div><span className="dp-connection-value dp-agent-value">{children}</span></div>;
}

// Each dialog owns its draft. Failed requests leave that draft open for correction.
export function SaveForm({ children, onSave, submit = '保存', description }) {
  const { close } = useDialog();
  const [error, setError] = useState('');
  const [pending, setPending] = useState(false);
  const submitting = useRef(false);
  return <form onSubmit={async (event) => {
    event.preventDefault(); if (submitting.current) return;
    const values = Object.fromEntries(new FormData(event.currentTarget));
    submitting.current = true; setPending(true); setError('');
    try { await onSave(values); close(); }
    catch (failure) { setError(failure.message || '保存失败，请重试'); }
    finally { submitting.current = false; setPending(false); }
  }}>{description && <p className="dp-dialog-description">{description}</p>}<fieldset disabled={pending}>{children}</fieldset>{error && <div className="dp-dialog-error" role="alert">{error}</div>}<div className="dp-form-actions"><Button onClick={close} disabled={pending}>取消</Button><Button type="submit" primary busy={pending}>{submit}</Button></div></form>;
}

export function DialogProvider({ children }) {
  const [dialog, setDialog] = useState(null);
  const close = () => setDialog(null);
  return <DialogContext.Provider value={{ open: (title, content, wide = false) => setDialog({ title, content, wide, opener: document.activeElement }), close }}><div inert={dialog ? true : undefined}>{children}</div>{dialog && <Dialog dialog={dialog} onClose={close} />}</DialogContext.Provider>;
}

function Dialog({ dialog, onClose }) {
  const ref = useRef(null);
  const onCloseRef = useRef(onClose); onCloseRef.current = onClose;
  const id = useId();
  useEffect(() => {
    const previous = dialog.opener;
    const modal = ref.current;
    (modal.querySelector('input, select, textarea') || modal.querySelector('button')).focus();
    const overflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    const keyDown = (event) => {
      if (event.key === 'Escape') { event.preventDefault(); onCloseRef.current(); }
      if (event.key !== 'Tab') return;
      const nodes = [...modal.querySelectorAll('button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled),[tabindex="0"]')].filter((node) => node.getClientRects().length && !node.closest('fieldset:disabled'));
      const first = nodes[0], last = nodes.at(-1);
      if (!first) { event.preventDefault(); modal.focus(); return; }
      if (event.shiftKey && (document.activeElement === first || !modal.contains(document.activeElement))) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    };
    document.addEventListener('keydown', keyDown);
    return () => { document.body.style.overflow = overflow; document.removeEventListener('keydown', keyDown); if (previous?.isConnected) previous.focus(); };
  }, []);
  return <div className="dp-overlay" onClick={(event) => { if (event.target === event.currentTarget) onClose(); }}><section ref={ref} tabIndex={-1} className={`dp-modal ${dialog.wide ? 'dp-public-key-modal' : ''}`} role="dialog" aria-modal="true" aria-labelledby={id}><div className="dp-modal-head"><h2 id={id}>{dialog.title}</h2><Button icon aria-label="关闭" onClick={onClose}><X /></Button></div><div className="dp-modal-body">{dialog.content}</div></section></div>;
}
