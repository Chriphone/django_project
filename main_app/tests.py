from django.test import TestCase, override_settings


class LoginPageRecaptchaTests(TestCase):
    @override_settings(
        RECAPTCHA_PUBLIC_KEY="test-public-recaptcha-key",
        STATICFILES_STORAGE="django.contrib.staticfiles.storage.StaticFilesStorage",
    )
    def test_login_page_uses_recaptcha_public_key_from_settings(self):
        response = self.client.get("/login_page")

        self.assertContains(response, 'data-sitekey="test-public-recaptcha-key"')
