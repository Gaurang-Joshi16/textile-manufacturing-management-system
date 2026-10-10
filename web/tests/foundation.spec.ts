import { test, expect } from '@playwright/test'

test.describe('authentication foundation', () => {
  test('unauthenticated visitors land on sign-in and do not see operational records', async ({ page }) => {
    await page.goto('/')
    await expect(page.getByRole('heading', { name: /sign in|log in/i })).toBeVisible()
    await expect(page.getByText(/orders in flight/i)).toHaveCount(0)
  })

  test('invalid credentials show a safe, human-readable error', async ({ page }) => {
    await page.goto('/#/login')
    await page.getByLabel(/email/i).fill('nobody@example.test')
    await page.getByLabel(/password/i).fill('not-a-real-password')
    await page.getByRole('button', { name: /sign in/i }).click()
    await expect(page.getByText(/email or password is incorrect/i)).toBeVisible()
  })
})
