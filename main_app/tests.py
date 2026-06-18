from django.test import TestCase, override_settings


class LoginPageRecaptchaTests(TestCase):
    @override_settings(RECAPTCHA_PUBLIC_KEY="test-public-recaptcha-key")
    def test_login_page_uses_recaptcha_public_key_from_settings(self):
        response = self.client.get("/login_page")

        self.assertContains(response, 'data-sitekey="test-public-recaptcha-key"')

    @override_settings(
        RECAPTCHA_ENABLED=False,
        RECAPTCHA_PUBLIC_KEY="invalid-domain-recaptcha-key",
    )
    def test_login_page_can_disable_recaptcha_widget(self):
        response = self.client.get("/login_page")

        self.assertNotContains(response, "www.google.com/recaptcha/api.js")
        self.assertNotContains(response, "g-recaptcha")
        self.assertNotContains(response, "data-sitekey=")


class ProductionStaticRenderingTests(TestCase):
    @override_settings(DEBUG=False, ALLOWED_HOSTS=["testserver"])
    def test_home_page_renders_with_debug_disabled(self):
        response = self.client.get("/")

        self.assertEqual(response.status_code, 200)


class HttpsRedirectTests(TestCase):
    @override_settings(
        ALLOWED_HOSTS=["kvtc.kmet.co.ke", "kvtc.kmet.co.ke:6065"],
        HTTPS_REDIRECT_ENABLED=True,
        HTTPS_REDIRECT_HOST="kvtc.kmet.co.ke:6065",
    )
    def test_http_request_redirects_to_configured_https_host(self):
        response = self.client.get(
            "/login_page?next=/admin/",
            HTTP_HOST="kvtc.kmet.co.ke",
        )

        self.assertEqual(response.status_code, 301)
        self.assertEqual(
            response["Location"],
            "https://kvtc.kmet.co.ke:6065/login_page?next=/admin/",
        )

    @override_settings(
        ALLOWED_HOSTS=["kvtc.kmet.co.ke", "kvtc.kmet.co.ke:6065"],
        HTTPS_REDIRECT_ENABLED=True,
        HTTPS_REDIRECT_HOST="kvtc.kmet.co.ke:6065",
    )
    def test_configured_https_host_does_not_redirect_again(self):
        response = self.client.get(
            "/",
            secure=True,
            HTTP_HOST="kvtc.kmet.co.ke:6065",
        )

        self.assertEqual(response.status_code, 200)
