import SwiftUI

struct LoginView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var phone = ""
    @State private var otp = ""
    @State private var isOTPSent = false
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var showRegistration = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // Modern gradient background
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.1, green: 0.2, blue: 0.45),
                        Color(red: 0.05, green: 0.35, blue: 0.85)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                // Animated background elements
                GeometryReader { geometry in
                    Circle()
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 300, height: 300)
                        .offset(x: -100, y: -50)
                        .blur(radius: 40)
                    
                    Circle()
                        .fill(Color.blue.opacity(0.08)) // Changed from .cyan
                        .frame(width: 250, height: 250)
                        .offset(x: geometry.size.width - 120, y: geometry.size.height - 150)
                        .blur(radius: 50)
                }
                
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer()
                            .frame(height: 50)
                        
                        // Brand Header
                        VStack(spacing: 20) {
                            // App Icon
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            gradient: Gradient(colors: [
                                                Color.white.opacity(0.25),
                                                Color.white.opacity(0.1)
                                            ]),
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 110, height: 110)
                                    .shadow(color: Color.black.opacity(0.1), radius: 20, x: 0, y: 10)
                                
                                Image(systemName: "bell.badge.fill")
                                    .font(.system(size: 52))
                                    .foregroundColor(.white) // Changed from foregroundStyle
                                    .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 2)
                            }
                            
                            VStack(spacing: 8) {
                                Text("ICCC Alert")
                                    .font(.system(size: 40, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 2)
                                
                                Text("Real-time monitoring & alerts")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .kerning(0.5) // Changed from .tracking
                            }
                        }
                        .padding(.bottom, 50)
                        
                        // Main Card
                        VStack(spacing: 0) {
                            // Card Header
                            VStack(spacing: 12) {
                                Text(isOTPSent ? "Verification" : "Welcome")
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundColor(.primary)
                                
                                Text(isOTPSent ? "Enter the 6-digit code sent to\n+91 \(phone)" : "Sign in to your account")
                                    .font(.system(size: 15))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                            .padding(.bottom, 36)
                            
                            // Input Section
                            VStack(spacing: 20) {
                                if !isOTPSent {
                                    // Phone Input
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("MOBILE NUMBER")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.secondary)
                                            .kerning(0.8)
                                        
                                        HStack(spacing: 16) {
                                            // Country Code
                                            HStack(spacing: 8) {
                                                Text("🇮🇳")
                                                    .font(.system(size: 20))
                                                Text("+91")
                                                    .font(.system(size: 17, weight: .medium))
                                                    .foregroundColor(.primary)
                                            }
                                            .padding(.vertical, 18)
                                            .padding(.horizontal, 16)
                                            .background(Color(.systemGray6))
                                            .cornerRadius(14)
                                            
                                            // Phone Input
                                            TextField("", text: $phone)
                                                .placeholder(when: phone.isEmpty) {
                                                    Text("Enter 10-digit number")
                                                        .foregroundColor(.secondary.opacity(0.6))
                                                }
                                                .keyboardType(.numberPad)
                                                .textContentType(.telephoneNumber)
                                                .font(.system(size: 17, weight: .medium))
                                                .foregroundColor(.primary)
                                                .padding(.vertical, 18)
                                                .padding(.horizontal, 20)
                                                .background(Color(.systemGray6))
                                                .cornerRadius(14)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 14)
                                                        .stroke(phone.count == 10 ? Color.blue : Color.clear, lineWidth: 2)
                                                )
                                        }
                                    }
                                } else {
                                    // OTP Input
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("VERIFICATION CODE")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.secondary)
                                            .kerning(0.8)
                                        
                                        HStack(spacing: 12) {
                                            Image(systemName: "lock.shield.fill")
                                                .font(.system(size: 20))
                                                .foregroundColor(.blue)
                                                .frame(width: 24)
                                            
                                            TextField("", text: $otp)
                                                .placeholder(when: otp.isEmpty) {
                                                    Text("Enter 6-digit OTP")
                                                        .foregroundColor(.secondary.opacity(0.6))
                                                }
                                                .keyboardType(.numberPad)
                                                .textContentType(.oneTimeCode)
                                                .font(.system(size: 20, weight: .semibold))
                                                .kerning(3) // Changed from .tracking
                                                .foregroundColor(.primary)
                                        }
                                        .padding(.vertical, 18)
                                        .padding(.horizontal, 20)
                                        .background(Color(.systemGray6))
                                        .cornerRadius(14)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14)
                                                .stroke(otp.count >= 4 ? Color.blue : Color.clear, lineWidth: 2)
                                        )
                                    }
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)
                                    ))
                                }
                            }
                            .padding(.horizontal, 28)
                            
                            // Action Button
                            Button(action: handleAction) {
                                ZStack {
                                    if isLoading {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    } else {
                                        HStack(spacing: 12) {
                                            Text(isOTPSent ? "Verify & Continue" : "Send OTP")
                                                .font(.system(size: 17, weight: .semibold))
                                            
                                            Image(systemName: isOTPSent ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                                                .font(.system(size: 20))
                                        }
                                    }
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(
                                    Group {
                                        if isButtonDisabled {
                                            Color.gray.opacity(0.5)
                                        } else {
                                            LinearGradient(
                                                gradient: Gradient(colors: [
                                                    Color(red: 0.05, green: 0.35, blue: 0.85),
                                                    Color(red: 0.1, green: 0.45, blue: 0.95)
                                                ]),
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        }
                                    }
                                )
                                .cornerRadius(16)
                                .shadow(
                                    color: isButtonDisabled ? .clear : Color.blue.opacity(0.4),
                                    radius: 12,
                                    x: 0,
                                    y: 6
                                )
                            }
                            .disabled(isButtonDisabled)
                            .padding(.horizontal, 28)
                            .padding(.top, 28)
                            
                            // Secondary Action
                            if isOTPSent {
                                Button(action: resetLogin) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 14, weight: .medium))
                                        Text("Change Number")
                                            .font(.system(size: 15, weight: .medium))
                                    }
                                    .foregroundColor(.blue)
                                    .padding(.vertical, 12)
                                }
                                .padding(.top, 16)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            }
                            
                            Spacer()
                                .frame(height: 40)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 30)
                                .fill(Color(.systemBackground))
                                .shadow(color: Color.black.opacity(0.15), radius: 30, x: 0, y: 15)
                        )
                        .padding(.horizontal, 20)
                        
                        // Register Section
                        VStack(spacing: 16) {
                            HStack(spacing: 8) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.3))
                                    .frame(height: 1)
                                
                                Text("or")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                                
                                Rectangle()
                                    .fill(Color.white.opacity(0.3))
                                    .frame(height: 1)
                            }
                            .padding(.horizontal, 40)
                            
                            Button(action: { showRegistration = true }) {
                                VStack(spacing: 8) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "person.badge.plus")
                                            .font(.system(size: 18))
                                        Text("Create New Account")
                                            .font(.system(size: 16, weight: .semibold))
                                    }
                                    .foregroundColor(.white)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(Color.white.opacity(0.15))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16)
                                                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                                        )
                                )
                            }
                            .padding(.horizontal, 20)
                        }
                        .padding(.top, 32)
                        .padding(.bottom, 50)
                    }
                }
            }
            .navigationBarHidden(true)
            .alert(isPresented: $showError) {
                Alert(
                    title: Text("Error"),
                    message: Text(errorMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(isPresented: $showRegistration) {
                RegistrationView()
            }
        }
    }
    
    private var isButtonDisabled: Bool {
        if isLoading { return true }
        if isOTPSent {
            return otp.count < 4
        } else {
            return phone.count != 10
        }
    }
    
    private func handleAction() {
        if isOTPSent {
            verifyOTP()
        } else {
            requestOTP()
        }
    }
    
    private func requestOTP() {
        guard phone.count == 10 else {
            errorMessage = "Please enter a valid 10-digit phone number"
            showError = true
            return
        }
        
        isLoading = true
        
        authManager.requestOTP(phone: phone) { success, message in
            isLoading = false
            
            if success {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    isOTPSent = true
                }
                print("✅ OTP sent successfully")
            } else {
                errorMessage = message
                showError = true
                print("❌ OTP request failed: \(message)")
            }
        }
    }
    
    private func verifyOTP() {
        guard otp.count >= 4 else {
            errorMessage = "Please enter a valid OTP"
            showError = true
            return
        }
        
        isLoading = true
        
        authManager.verifyOTP(phone: phone, otp: otp) { success, message in
            isLoading = false
            
            if success {
                print("✅ Login successful")
            } else {
                errorMessage = message
                showError = true
                otp = ""
            }
        }
    }
    
    private func resetLogin() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            isOTPSent = false
            otp = ""
        }
    }
}

// Helper extension for placeholder
extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content) -> some View {
        
        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}

struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
            .environmentObject(AuthManager.shared)
    }
}