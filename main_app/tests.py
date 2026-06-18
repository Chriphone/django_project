from django.test import TestCase, override_settings


class LoginPageRecaptchaTests(TestCase):
    @override_settings(RECAPTCHA_PUBLIC_KEY="test-public-recaptcha-key")
    def test_login_page_uses_recaptcha_public_key_from_settings(self):
        response = self.client.get("/login_page")

        self.assertContains(response, 'data-sitekey="test-public-recaptcha-key"')


class ProductionStaticRenderingTests(TestCase):
    @override_settings(DEBUG=False, ALLOWED_HOSTS=["testserver"])
    def test_home_page_renders_with_debug_disabled(self):
        response = self.client.get("/")

        self.assertEqual(response.status_code, 200)
