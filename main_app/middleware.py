from django.utils.deprecation import MiddlewareMixin
from django.urls import reverse
from django.shortcuts import redirect
from django.conf import settings
from django.http import HttpResponsePermanentRedirect


class HttpsRedirectMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if self.should_redirect(request):
            redirect_host = getattr(settings, "HTTPS_REDIRECT_HOST", "") or request.get_host()
            return HttpResponsePermanentRedirect(f"https://{redirect_host}{request.get_full_path()}")

        return self.get_response(request)

    def should_redirect(self, request):
        if not getattr(settings, "HTTPS_REDIRECT_ENABLED", False):
            return False

        if request.is_secure():
            return False

        forwarded_proto = request.META.get("HTTP_X_FORWARDED_PROTO", "").split(",")[0].strip().lower()
        if forwarded_proto == "https":
            return False

        if request.META.get("HTTPS", "").lower() in ("on", "1"):
            return False

        redirect_host = getattr(settings, "HTTPS_REDIRECT_HOST", "")
        if redirect_host and request.get_host().lower() == redirect_host.lower():
            return False

        return True


class LoginCheckMiddleWare(MiddlewareMixin):
    def process_view(self, request, view_func, view_args, view_kwargs):
        modulename = view_func.__module__
        user = request.user # Who is the current user ?
        if user.is_authenticated:
            if user.user_type == '1': # Is it the HOD/Admin
                if modulename == 'main_app.student_views':
                    return redirect(reverse('admin_home'))
            elif user.user_type == '2': #  Staff :-/ ?
                if modulename == 'main_app.student_views' or modulename == 'main_app.hod_views':
                    return redirect(reverse('staff_home'))
            elif user.user_type == '3': # ... or Student ?
                if modulename == 'main_app.hod_views' or modulename == 'main_app.staff_views':
                    return redirect(reverse('student_home'))
            else: # None of the aforementioned ? Please take the user to login page
                return redirect(reverse('login_page'))
        else:
            if request.path == reverse('login_page') or modulename == 'django.contrib.auth.views' or request.path == reverse('user_login'): # If the path is login or has anything to do with authentication, pass
                pass
            else:
                return redirect(reverse('login_page'))
