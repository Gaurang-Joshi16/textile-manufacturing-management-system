import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import { AuthGate, AuthProvider } from './Auth'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <AuthProvider>
      <AuthGate><App /></AuthGate>
    </AuthProvider>
  </StrictMode>,
)
