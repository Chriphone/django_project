import json
import requests
from django.conf import settings
from django.contrib import messages
from django.contrib.auth import authenticate, login, logout
#from django.contrib.auth.forms importUserCreationForm
from django.http import HttpResponse, JsonResponse
from django.shortcuts import get_object_or_404, redirect, render, reverse
from django.views.decorators.csrf import csrf_exempt
import dj_database_url
from .forms import RegisterForm



from .models import Attendance, CustomUser, Session, Student, Subject

#Create your views here.
def home(request):
    return render(request, 'main_app/homepage/index.html', {})


def courses(request):
    return render(request, 'main_app/homepage/index.html', {})


def cdacc(request):
    return render(request, 'main_app/homepage/cdacccourses.html', {})


def nita(request):
    return render(request, 'main_app/homepage/nitacourses.html', {})


def short(request):
    return render(request, 'main_app/homepage/shortcourse.html', {})


def coursedetail(request):
    return render(request, 'main_app/homepage/coursedetail/course detail.html', {})


def homes(request):
    return render(request, 'main_app/registration/registration.html', {})



    

def login_page(request):
    if request.user.is_authenticated:
        if request.user.user_type == '1':
            return redirect(reverse("admin_home"))
        elif request.user.user_type == '2':
            return redirect(reverse("staff_home"))
        else:
            return redirect(reverse("student_home"))
    return render(
        request,
        'main_app/login.html',
        {
            'recaptcha_enabled': settings.RECAPTCHA_ENABLED,
            'recaptcha_public_key': settings.RECAPTCHA_PUBLIC_KEY,
        },
    )
def register_page(request):
    if request.method == 'POST':
        form = RegisterForm(request.POST)
        if form.is_valid():
            full_name = form.cleaned_data['username'].strip()
            name_parts = full_name.split(maxsplit=1)
            first_name = name_parts[0]
            last_name = name_parts[1] if len(name_parts) > 1 else ""
            user = CustomUser.objects.create_user(
                email=form.cleaned_data['email'],
                password=form.cleaned_data['password'],
                first_name=first_name,
                last_name=last_name,
                user_type='3',
                gender='M',
                address='',
            )
            Student.objects.get_or_create(admin=user)
            return redirect('/login/')
    else:
        form = RegisterForm()

    return render(request, 'main_app/homepage/register.html', {'form': form})

def doLogin(request, **kwargs):
    if request.method != 'POST':
        return HttpResponse("<h4>Denied</h4>")
    
    # Extract POST data cleanly
    email = request.POST.get('email')
    password = request.POST.get('password')
    
    user = authenticate(request, username=email, password=password)
    
    if user is not None:
        login(request, user)
        if user.user_type == '1':
            return redirect(reverse("admin_home"))
        elif user.user_type == '2':
            return redirect(reverse("staff_home"))
        else:
            return redirect(reverse("student_home"))
    else:
        messages.error(request, "Invalid details")
        # Replace with your named URL pattern (e.g., 'login') or keep the template path
        return redirect("login_page")
        
    # Final fallback return to ensure the view never returns None
    return redirect("login_page")
    

def logout_user(request):
    if request.user != None:
        logout(request)
    #return redirect("/")
    return render(request, 'main_app/homepage/home_page.html', {})


@csrf_exempt
def get_attendance(request):
    subject_id = request.POST.get('subject')
    session_id = request.POST.get('session')
    try:
        subject = get_object_or_404(Subject, id=subject_id)
        session = get_object_or_404(Session, id=session_id)
        attendance = Attendance.objects.filter(subject=subject, session=session)
        attendance_list = []
        for attd in attendance:
            data = {
                    "id": attd.id,
                    "attendance_date": str(attd.date),
                    "session": attd.session.id
                    }
            attendance_list.append(data)
        return JsonResponse(json.dumps(attendance_list), safe=False)
    except Exception as e:
        return None


def showFirebaseJS(request):
    data = """
    // Give the service worker access to Firebase Messaging.
// Note that you can only use Firebase Messaging here, other Firebase libraries
// are not available in the service worker.
importScripts('https://www.gstatic.com/firebasejs/7.22.1/firebase-app.js');
importScripts('https://www.gstatic.com/firebasejs/7.22.1/firebase-messaging.js');

// Initialize the Firebase app in the service worker by passing in
// your app's Firebase config object.
// https://firebase.google.com/docs/web/setup#config-object
firebase.initializeApp({
    apiKey: "AIzaSyBarDWWHTfTMSrtc5Lj3Cdw5dEvjAkFwtM",
    authDomain: "sms-with-django.firebaseapp.com",
    databaseURL: "https://sms-with-django.firebaseio.com",
    projectId: "sms-with-django",
    storageBucket: "sms-with-django.appspot.com",
    messagingSenderId: "945324593139",
    appId: "1:945324593139:web:03fa99a8854bbd38420c86",
    measurementId: "G-2F2RXTL9GT"
});

// Retrieve an instance of Firebase Messaging so that it can handle background
// messages.
const messaging = firebase.messaging();
messaging.setBackgroundMessageHandler(function (payload) {
    const notification = JSON.parse(payload);
    const notificationOption = {
        body: notification.body,
        icon: notification.icon
    }
    return self.registration.showNotification(payload.notification.title, notificationOption);
});
    """
    return HttpResponse(data, content_type='application/javascript')

def register(request):
    return register_page(request)
